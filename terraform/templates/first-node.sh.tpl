#!/usr/bin/env bash
set -x

# 1. Register SLES with SUSE Customer Center
# set +x/-x brackets this so the registration code isn't traced into cloud-init logs.
set +x
SUSEConnect -r "${sles_reg_code}"
set -x

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
ingress-controller:
  - ${rke2_ingress_controller}
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

# Wait for RKE2 components to be ready. This is crucial to avoid race conditions.
echo "Waiting for RKE2 API server to be ready..."
timeout 180s bash -c 'while [[ "$(curl -k -s -o /dev/null -w ''%%{http_code}'' https://127.0.0.1:6443/ping)" != "200" ]]; do echo "Waiting for API server..."; sleep 5; done'

echo "Waiting for core RKE2 components (DNS and Ingress) to be ready..."
# RKE2's CoreDNS addon deploys as the "rke2-coredns-rke2-coredns" Deployment;
# "kube-dns" is only the compatibility Service name, not a workload.
kubectl wait --for=condition=Available deployment/rke2-coredns-rke2-coredns -n kube-system --timeout=300s || {
  echo "Error: Timed out waiting for CoreDNS (deployment/rke2-coredns-rke2-coredns) to become available." >&2
  exit 1
}
# RKE2's packaged ingress controller (ingress-nginx, or traefik from v1.36 onward)
# runs as a DaemonSet, not a Deployment, so it has no "Available" condition; wait on
# rollout status instead.
kubectl rollout status daemonset/${ingress_daemonset_name} -n kube-system --timeout=300s || {
  echo "Error: Timed out waiting for the ingress controller (daemonset/${ingress_daemonset_name}) to become ready." >&2
  exit 1
}
echo "RKE2 core components are ready."

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

%{ if use_letsencrypt ~}
# Create a ClusterIssuer for Let's Encrypt. This tells cert-manager how to obtain certificates.
echo "Creating Let's Encrypt ClusterIssuer..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: "${letsencrypt_email}"
    privateKeySecretRef:
      name: letsencrypt-prod-private-key
    solvers:
    - http01:
        ingress:
          ingressClassName: ${ingress_class_name}
EOF
%{ endif ~}
# 8. Deploy Rancher via Helm
helm repo add rancher-prime https://charts.rancher.com/server-charts/prime
helm repo update

# Ensure the cattle-system namespace exists before creating secrets in it.
kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -

# --- Configure TLS ---
# This section conditionally configures TLS based on the 'use_letsencrypt' variable.

%{ if !use_letsencrypt ~}
# --- Custom Certificate Configuration ---
echo "Configuring Rancher with custom TLS certificate."

# Create the TLS secret for the ingress from the provided data.
# The Rancher Helm chart's default secret name when ingress.tls.source=secret
# is cattle-system/tls-rancher-ingress. Use that name directly instead of a
# custom one + an `ingress.tls.secretName` override: if the Ingress ever ends
# up referencing a secret that doesn't exist (e.g. a typo in that override),
# the ingress controller silently falls back to serving its default
# self-signed "Kubernetes Ingress Controller Fake Certificate" instead of
# failing loudly.
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: tls-rancher-ingress
  namespace: cattle-system
type: kubernetes.io/tls
data:
  tls.crt: ${tls_cert_b64}
  tls.key: ${tls_key_b64}
EOF

# If a CA certificate is provided, create the 'tls-ca' secret.
# This makes Rancher trust the custom CA for downstream agents.
%{ if ca_cert_b64 != "" ~}
echo "Custom CA certificate provided. Creating tls-ca secret."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: tls-ca
  namespace: cattle-system
type: Opaque
data:
  cacerts.pem: ${ca_cert_b64}
EOF
PRIVATE_CA_OPTS="--set privateCA=true"
%{ else ~}
PRIVATE_CA_OPTS="--set privateCA=false"
%{ endif ~}

# Set Helm chart values to use the custom secret (tls-rancher-ingress, created above).
TLS_SOURCE_OPTS="--set ingress.tls.source=secret"

%{ else ~}
# --- Let's Encrypt Configuration ---
echo "Configuring Rancher with Let's Encrypt."

# Decouple certificate creation from the Rancher install to prevent race conditions.
# 1. Wait for rancher_hostname to resolve to this load balancer in public DNS.
# 2. Create a Certificate resource manually.
# 3. Wait for cert-manager to issue the certificate and create the secret.
# 4. Install Rancher, telling it to use the pre-existing secret.

# Let's Encrypt's HTTP-01 challenge is validated by Let's Encrypt's own resolvers,
# not this VM's local DNS. Terraform creating the DNS record (or a user creating it
# manually) does not mean it has propagated yet, so poll a public DNS-over-HTTPS
# resolver directly (avoids depending on dig/host, which aren't installed by default
# on this image) until it resolves before ever requesting a certificate.
wait_for_public_dns() {
  echo "Waiting for ${rancher_hostname} to resolve to ${lb_ip} in public DNS before requesting a Let's Encrypt certificate..."
  local end_time=$((SECONDS + 600))
  while [ $SECONDS -lt $end_time ]; do
    resolved_ip=$(curl --silent --max-time 10 "https://dns.google/resolve?name=${rancher_hostname}&type=A" \
      | grep -o '"data":"[0-9.]*"' | head -n1 | cut -d'"' -f4)
    if [ "$resolved_ip" = "${lb_ip}" ]; then
      echo "DNS resolution confirmed: ${rancher_hostname} -> $resolved_ip"
      return 0
    fi
    echo "DNS not ready yet (got '$${resolved_ip:-<no answer>}', want ${lb_ip}). Retrying in 15s..."
    sleep 15
  done
  return 1
}

if ! wait_for_public_dns; then
  echo "Error: Timed out after 10 minutes waiting for ${rancher_hostname} to resolve to ${lb_ip}." >&2
  echo "The Let's Encrypt HTTP-01 challenge requires this to succeed first. Check the DNS record (Route53 or manual) and retry." >&2
  exit 1
fi

echo "Creating Certificate resource to trigger Let's Encrypt..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: rancher-tls-cert
  namespace: cattle-system
spec:
  secretName: rancher-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - "${rancher_hostname}"
EOF

echo "Waiting for Let's Encrypt certificate to be issued... This can take several minutes."
kubectl wait --for=condition=Ready certificate/rancher-tls-cert -n cattle-system --timeout=600s || {
  echo "Error: Timed out waiting for the Let's Encrypt certificate 'rancher-tls-cert' to become Ready." >&2
  echo "--- cert-manager diagnostics (certificate/rancher-tls-cert) ---" >&2
  kubectl describe certificate rancher-tls-cert -n cattle-system >&2 || true
  echo "--- cert-manager diagnostics (challenges) ---" >&2
  kubectl get challenges -n cattle-system -o wide >&2 || true
  kubectl describe challenges -n cattle-system >&2 || true
  echo "Refusing to install Rancher against a certificate that was never issued." >&2
  exit 1
}
echo "Certificate 'rancher-tls' has been successfully issued."

# Set Helm chart values to use the secret that was just created.
TLS_SOURCE_OPTS="--set ingress.tls.source=secret --set ingress.tls.secretName=rancher-tls"
PRIVATE_CA_OPTS=""
%{ endif ~}


# --- Install/Upgrade Rancher Helm Chart ---
echo "Installing Rancher via Helm..."

# Conditionally set the version flag for Helm. If no version is specified,
# Helm will automatically use the latest version from the repository.
RANCHER_VERSION_OPTS=""
if [[ -n "${rancher_version}" ]]; then
  RANCHER_VERSION_OPTS="--version ${rancher_version}"
fi

# set +x/-x brackets this so the bootstrap password isn't traced into cloud-init logs.
set +x
helm upgrade --install rancher rancher-prime/rancher \
  --namespace cattle-system \
  --create-namespace \
  $RANCHER_VERSION_OPTS \
  --set hostname=${rancher_hostname} \
  --set bootstrapPassword=${rancher_bootstrap_password} \
  --set ingress.ingressClassName=${ingress_class_name} \
  $TLS_SOURCE_OPTS \
  $PRIVATE_CA_OPTS
set -x


# 9. Wait for Rancher and configure settings

# Wait for the Rancher deployment to become available before attempting to change settings.
echo "Waiting for Rancher deployment to be ready..."
kubectl rollout status deployment/rancher -n cattle-system --timeout=600s
echo "Rancher deployment is ready."

# 10. Configure Rancher AI (Liz) with the selected LLM provider, if any
%{ if ai_llm_provider == "" ~}
echo "ai_llm_provider is unset; skipping Rancher AI Assistant installation."
%{ else ~}
echo "Configuring Rancher AI with LLM provider: ${ai_llm_provider}..."

# Install the AI agent, configured for the selected LLM provider.
# set +x/-x brackets this so API keys/tokens aren't traced into cloud-init logs.
set +x
helm install rancher-ai-agent \
  --namespace cattle-ai-agent-system \
  --create-namespace \
  --set activeLlm=${ai_llm_provider} \
%{ if ai_llm_provider == "gemini" ~}
  --set geminiLlmModel="${gemini_model}" \
  --set googleApiKey="${gemini_api_key}" \
%{ endif ~}
%{ if ai_llm_provider == "openai" ~}
  --set openaiLlmModel="${openai_model}" \
  --set openaiApiKey="${openai_api_key}" \
%{ endif ~}
%{ if ai_llm_provider == "bedrock" ~}
  --set bedrockLlmModel="${bedrock_model}" \
  --set awsBedrock.bearerToken="${bedrock_bearer_token}" \
  --set awsBedrock.region="${bedrock_region}" \
%{ if bedrock_url != "" ~}
  --set awsBedrock.url="${bedrock_url}" \
%{ endif ~}
%{ endif ~}
%{ if ai_llm_provider == "ollama" ~}
  --set ollamaLlmModel="${ollama_model}" \
  --set ollamaUrl="${ollama_url}" \
%{ endif ~}
%{ if ai_llm_provider == "generic-openai" ~}
  --set genericOpenaiLlmModel="${generic_openai_model}" \
  --set genericOpenaiUrl="${generic_openai_url}" \
  --set genericOpenaiApiKey="${generic_openai_api_key}" \
%{ endif ~}
  oci://registry.suse.com/rancher/charts/rancher-ai-agent
set -x
%{ endif ~}

# Final health check to ensure Rancher is fully available before script exits.
# This polls the ingress endpoint to confirm the application is responsive.
# We use --resolve to bypass DNS and test the ingress rule for the correct hostname.
echo "Performing final health check on Rancher..."

health_check_command() {
  # When using Let's Encrypt, we do a strict check (no -k) to validate the cert.
  # For custom certs, we must use -k as the custom CA won't be trusted by the OS.
  %{ if use_letsencrypt ~}
  curl --fail --silent --show-error --connect-timeout 10 --resolve ${rancher_hostname}:443:127.0.0.1 https://${rancher_hostname}/healthz > /dev/null
  %{ else ~}
  [[ "$(curl -k --resolve ${rancher_hostname}:443:127.0.0.1 -s -o /dev/null -w '%%{http_code}' https://${rancher_hostname}/healthz)" == "200" ]]
  %{ endif ~}
}

# `timeout ... bash -c '...'` would spawn a separate bash process that doesn't
# inherit the health_check_command function, so poll in this shell instead,
# using the same SECONDS-based timeout pattern as wait_for_public_dns above.
health_check_end_time=$((SECONDS + 480))
while ! health_check_command; do
  if [ $SECONDS -ge $health_check_end_time ]; then
    echo "Timed out waiting for Rancher to become healthy." >&2
    exit 1
  fi
  echo "Waiting for Rancher to become healthy with a valid certificate..."
  sleep 15
done
echo "Rancher is healthy and fully available."
