#!/usr/bin/env bash
set -x

# 0. Set the OS hostname (see first-node.sh.tpl for why this must come first).
hostnamectl set-hostname "${vm_hostname}"

# 1. Register SLES with SUSE Customer Center
# set +x/-x brackets this so the registration code isn't traced into cloud-init logs.
set +x
SUSEConnect -r "${sles_reg_code}"
set -x

# 2. Kernel & OS prep for RKE2
systemctl stop apparmor || true
systemctl disable apparmor || true

%{ if install_suse_storage ~}
# Prepare the dedicated data disk for SUSE Storage (Longhorn), SUSE AI
# Factory's block-storage prerequisite. See downstream-node.sh.tpl's matching
# comment for why the device is detected rather than assumed.
echo "Looking for the SUSE Storage data disk..."
DATA_DISK=""
for dev in $(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
  line_count=$(lsblk -n "/dev/$dev" | wc -l)
  fstype=$(lsblk -dn -o FSTYPE "/dev/$dev")
  if [[ "$line_count" -eq 1 && -z "$fstype" ]]; then
    DATA_DISK="/dev/$dev"
    break
  fi
done

if [[ -z "$DATA_DISK" ]]; then
  echo "Error: install_suse_storage is true, but no unformatted data disk was found." >&2
  lsblk >&2
  exit 1
fi

echo "Formatting $DATA_DISK and mounting at /var/lib/longhorn..."
mkfs.ext4 -F "$DATA_DISK"
mkdir -p /var/lib/longhorn
echo "$DATA_DISK /var/lib/longhorn ext4 defaults 0 2" >> /etc/fstab
mount /var/lib/longhorn
echo "SUSE Storage data disk ready at /var/lib/longhorn."
%{ endif ~}

# 3. Create RKE2 config directory
mkdir -p /etc/rancher/rke2

# No tls-san needed: this cluster has no load balancer or public hostname of
# its own - the management cluster's cattle-cluster-agent reaches out to it,
# not the other way around.
cat <<EOF > /etc/rancher/rke2/config.yaml
token: "${downstream_rke2_token}"
cni:
  - canal
write-kubeconfig-mode: "0640"
EOF

# 4. Install & Start RKE2
# See first-node.sh.tpl for why an empty rke2_version is resolved here rather
# than left to get.rke2.io's own (broken) channel resolution.
RKE2_VERSION="${downstream_rke2_version}"
if [[ -z "$RKE2_VERSION" ]]; then
  echo "Resolving RKE2 'stable' channel version from update.rke2.io..."
  for attempt in $(seq 1 10); do
    CHANNELS_JSON=$(curl -sfL https://update.rke2.io/v1-release/channels)
    if [[ $? -eq 0 ]]; then
      RKE2_VERSION=$(echo "$CHANNELS_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(next(c["latest"] for c in data["data"] if c["id"] == "stable"))
')
      [[ -n "$RKE2_VERSION" ]] && break
    fi
    echo "Attempt $attempt/10: failed to resolve RKE2 version from update.rke2.io; retrying in 10s..." >&2
    sleep 10
  done
  if [[ -z "$RKE2_VERSION" ]]; then
    echo "Error: Could not resolve RKE2 'stable' channel version from update.rke2.io after 10 attempts." >&2
    exit 1
  fi
  echo "Resolved RKE2 'stable' channel to version: $RKE2_VERSION"
fi
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="$RKE2_VERSION" INSTALL_RKE2_TYPE="server" sh -
systemctl enable rke2-server.service || { echo "Error: rke2-server.service unit not found; RKE2 install likely failed." >&2; exit 1; }
systemctl start rke2-server.service || { echo "Error: rke2-server.service failed to start." >&2; exit 1; }

# 5. Environment setup for kubectl
export PATH=$PATH:/var/lib/rancher/rke2/bin
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

echo "export PATH=\$PATH:/var/lib/rancher/rke2/bin" >> /etc/profile
echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml" >> /etc/profile

echo "Waiting for RKE2 API server to be ready..."
timeout 180s bash -c 'until kubectl get --raw=/readyz &>/dev/null; do echo "Waiting for API server..."; sleep 5; done' || {
  echo "Error: Timed out waiting for the RKE2 API server to respond on 127.0.0.1:6443." >&2
  echo "--- rke2-server.service status ---" >&2
  systemctl status rke2-server.service --no-pager >&2 || true
  echo "--- rke2-server.service logs (last 100 lines) ---" >&2
  journalctl -u rke2-server.service --no-pager | tail -100 >&2 || true
  exit 1
}

echo "Waiting for core RKE2 components (DNS) to be ready..."
end_time=$((SECONDS + 300))
until kubectl wait --for=condition=Available deployment/rke2-coredns-rke2-coredns -n kube-system --timeout=10s &>/dev/null; do
  if [ $SECONDS -ge $end_time ]; then
    echo "Error: Timed out waiting for CoreDNS (deployment/rke2-coredns-rke2-coredns) to become available." >&2
    kubectl get deployment -n kube-system >&2 || true
    exit 1
  fi
  echo "Waiting for CoreDNS deployment to exist and become available..."
  sleep 5
done
echo "RKE2 core components are ready."

# 6. Register this cluster with the Rancher management cluster by applying
# the registration manifest Rancher generated for it (see rancher.tf). The
# manifest URL only becomes known once Rancher's cluster object exists, which
# Terraform already sequences ahead of this VM's creation - but the
# cattle-cluster-agent image/CRDs it references can still need a few tries
# right after the cluster object was just created, hence the retry loop.
echo "Registering this cluster with Rancher..."
registration_end_time=$((SECONDS + 300))
until kubectl apply -f "${registration_manifest_url}" &>/dev/null; do
  if [ $SECONDS -ge $registration_end_time ]; then
    echo "Error: Timed out applying the Rancher cluster registration manifest." >&2
    exit 1
  fi
  echo "Registration manifest not applyable yet; retrying in 15s..."
  sleep 15
done

echo "Waiting for the Rancher cluster agent to roll out..."
kubectl rollout status deployment/cattle-cluster-agent -n cattle-system --timeout=300s || {
  echo "Error: Timed out waiting for deployment/cattle-cluster-agent to become ready." >&2
  echo "--- cattle-system pods ---" >&2
  kubectl get pods -n cattle-system >&2 || true
  for pod in $(kubectl get pods -n cattle-system -l app=cattle-cluster-agent -o name 2>/dev/null); do
    kubectl logs -n cattle-system "$pod" --all-containers --tail=200 >&2 || true
  done
  exit 1
}
echo "Cluster successfully registered with Rancher."
