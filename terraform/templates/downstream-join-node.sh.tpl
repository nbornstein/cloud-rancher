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
# Every node in the cluster needs its own Longhorn-ready disk, not just the
# server - see downstream-first-node.sh.tpl's matching comment.
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

# Agent config: just the server to join and the shared token. No
# tls-san/cni/write-kubeconfig-mode - those are server-side settings this
# node doesn't need as a worker.
cat <<EOF > /etc/rancher/rke2/config.yaml
server: https://${first_node_ip}:9345
token: "${downstream_rke2_token}"
EOF

# 4. Install & Start RKE2 as an agent (worker only - no etcd/control-plane).
# Unlike join-node.sh.tpl (which joins a second *server* to the management
# cluster's HA control plane), this is a true worker node: SUSE AI Factory's
# multi-node minimum is about GPU compute capacity, not control-plane quorum.
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
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="$RKE2_VERSION" INSTALL_RKE2_TYPE="agent" sh -
systemctl enable rke2-agent.service || { echo "Error: rke2-agent.service unit not found; RKE2 install likely failed." >&2; exit 1; }
systemctl start rke2-agent.service || { echo "Error: rke2-agent.service failed to start." >&2; exit 1; }

# 5. Wait for the agent to come up. There's no local apiserver/kubeconfig to
# query on an agent node, so poll the systemd unit itself instead of
# `kubectl get --raw=/readyz` like the server-side templates do.
echo "Waiting for rke2-agent to become active..."
timeout 180s bash -c 'until systemctl is-active --quiet rke2-agent.service; do echo "Waiting for rke2-agent..."; sleep 5; done' || {
  echo "Error: Timed out waiting for rke2-agent.service to become active." >&2
  echo "--- rke2-agent.service status ---" >&2
  systemctl status rke2-agent.service --no-pager >&2 || true
  echo "--- rke2-agent.service logs (last 100 lines) ---" >&2
  journalctl -u rke2-agent.service --no-pager | tail -100 >&2 || true
  exit 1
}
echo "rke2-agent is active and has joined the cluster."
