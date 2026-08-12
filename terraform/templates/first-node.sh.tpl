#!/usr/bin/env bash
set -x

# 1. Register SLES with SUSE Customer Center
SUSEConnect -r "${sles_reg_code}"

# 2. Kernel & OS prep for RKE2
systemctl stop apparmor || true
systemctl disable apparmor || true

# 3. Create RKE2 config directory
mkdir -p /etc/rancher/rke2

cat <<EOF > /etc/rancher/rke2/config.yaml
token: "${rke2_token}"
tls-san:
  - "${lb_ip}"
  - "${rancher_hostname}"
cni:
  - canal
write-kubeconfig-mode: "0640"
EOF

# 4. Install & Start RKE2
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${rke2_version}" INSTALL_RKE2_TYPE="server" sh -
systemctl enable rke2-server.service
systemctl start rke2-server.service

# 5. Environment setup for kubectl & Helm
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

echo "export PATH=\$PATH:/var/lib/rancher/rke2/bin" >> /etc/profile
echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" >> /etc/profile

# 6. Install Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash -

# 7. Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${cert_manager_version}/cert-manager.yaml

# Wait for cert-manager to be ready before installing Rancher.
# The webhook is the last component to start and is critical for functionality.
echo "Waiting for cert-manager webhook to be ready..."
kubectl wait --for=condition=Available deployment/cert-manager-webhook \
  --namespace cert-manager --timeout=300s
echo "cert-manager webhook is ready."

# 8. Deploy Rancher via Helm
helm repo add rancher-prime https://charts.rancher.com/server-charts/prime
helm repo update

# Ensure the cattle-system namespace exists before creating secrets in it.
kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -

# --- Configure TLS ---
# This section conditionally configures TLS based on the 'use_letsencrypt' variable.

% if !use_letsencrypt ~%
# --- Custom Certificate Configuration ---
echo "Configuring Rancher with custom TLS certificate."

# Create the TLS secret for the ingress from the provided data.
# The secret is named 'suse-southeast-lab-certs' as you requested.
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: suse-southeast-lab-certs
  namespace: cattle-system
type: kubernetes.io/tls
data:
  tls.crt: ${tls_crt_b64}
  tls.key: ${tls_key_b64}
EOF

# If a CA certificate is provided, create the 'tls-ca' secret.
# This makes Rancher trust the custom CA for downstream agents.
% if ca_crt_b64 != "" ~%
echo "Custom CA certificate provided. Creating tls-ca secret."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: tls-ca
  namespace: cattle-system
type: Opaque
data:
  cacerts.pem: ${ca_crt_b64}
EOF
PRIVATE_CA_OPTS="--set privateCA=true"
% else ~%
PRIVATE_CA_OPTS="--set privateCA=false"
% endif ~%

# Set Helm chart values to use the custom secret.
TLS_SOURCE_OPTS="--set ingress.tls.source=secret --set ingress.tls.secretName=suse-southeast-lab-certs"

% else ~%
# --- Let's Encrypt Configuration ---
echo "Configuring Rancher with Let's Encrypt."

# Set Helm chart values for Let's Encrypt.
TLS_SOURCE_OPTS="--set ingress.tls.source=letsencrypt --set letsencrypt.email=${letsencrypt_email}"
PRIVATE_CA_OPTS=""
% endif ~%


# --- Install/Upgrade Rancher Helm Chart ---
echo "Installing Rancher via Helm..."

# Conditionally set the version flag for Helm. If no version is specified,
# Helm will automatically use the latest version from the repository.
RANCHER_VERSION_OPTS=""
if [[ -n "${rancher_version}" ]]; then
  RANCHER_VERSION_OPTS="--version ${rancher_version}"
fi

helm upgrade --install rancher rancher-prime/rancher \
  --namespace cattle-system \
  --create-namespace \
  $RANCHER_VERSION_OPTS \
  --set hostname=${rancher_hostname} \
  --set bootstrapPassword=${rancher_bootstrap_password} \
  $TLS_SOURCE_OPTS \
  $PRIVATE_CA_OPTS \
  %{~ if use_letsencrypt ~}
  # Disable HTTP to HTTPS redirect to allow the Let's Encrypt HTTP-01 challenge to succeed.
  --set ingress.extraAnnotations.'nginx\.ingress\.kubernetes\.io/ssl-redirect'="false"
  %{~ endif ~}
  # ... (keep any other --set flags you have for rancher, like for Gemini AI)


# 9. Wait for Rancher and configure settings

# Wait for the Rancher deployment to become available before attempting to change settings.
echo "Waiting for Rancher deployment to be ready..."
kubectl rollout status deployment/rancher -n cattle-system --timeout=600s
echo "Rancher deployment is ready."

# 10. Configure Rancher AI (Liz) with Google Gemini
echo "Configuring Rancher AI with Google Gemini..."

# Create the secret for the Gemini API key.
# Using apply with dry-run to make this step idempotent. The explicit kubeconfig is removed
# as it's already in the environment.
kubectl create secret generic llm-provider-google-gemini \
  --namespace cattle-system \
  --from-literal=apiKey="${gemini_api_key}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Set the LLM provider to google-gemini
helm install rancher-ai-agent \
  --namespace cattle-ai-agent-system \
  --create-namespace \
  --set activeLlm=gemini \
  --set geminiLlmModel="${gemini_model}" \
  --set googleApiKey="${gemini_api_key}" \
  oci://registry.suse.com/rancher/charts/rancher-ai-agent

# Final health check to ensure Rancher is fully available before script exits.
# This polls the ingress endpoint to confirm the application is responsive.
echo "Performing final health check on Rancher..."
timeout 300s bash -c 'while [[ "$(curl -k -s -o /dev/null -w ''%%{http_code}'' https://localhost/healthz)" != "200" ]]; do echo "Waiting for Rancher to be healthy..."; sleep 5; done'
if [ $? -ne 0 ]; then
  echo "Timed out waiting for Rancher to become healthy." >&2
  exit 1
fi
echo "Rancher is healthy and fully available."
