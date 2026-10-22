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
server: https://${first_node_ip}:9345
token: "${rke2_token}"
tls-san:
  - "${lb_ip}"
  - "${rancher_hostname}"
cni:
  - canal
write-kubeconfig-mode: "0640"
EOF

# 4. Install & Start RKE2 as server (Control-Plane + Etcd + Worker)
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${rke2_version}" INSTALL_RKE2_TYPE="server" sh -
systemctl enable rke2-server.service
systemctl start rke2-server.service
