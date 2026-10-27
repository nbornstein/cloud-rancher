#!/bin/bash
set -euo pipefail

# Set the OS hostname (see first-node.sh.tpl for why this must come first).
hostnamectl set-hostname "${vm_hostname}"

# Register SLES using the registration code passed from Terraform
SUSEConnect -r "${sles_reg_code}"
SUSEConnect -p sle-module-public-cloud/15.7/x86_64
zypper --non-interactive --gpg-auto-import-keys refresh
zypper --non-interactive update -y

%{ if install_suse_storage ~}
# Prepare the dedicated data disk for SUSE Storage (Longhorn), the
# block-storage prerequisite for SUSE AI Factory. Longhorn itself isn't
# installed here - these nodes have no Kubernetes cluster yet (see README's
# Downstream Nodes section) - this just leaves the disk formatted and mounted
# at Longhorn's default data path, ready for whenever the node is registered.
#
# The attached device name isn't identified directly (e.g. AWS's requested
# "/dev/sdf"): Nitro-based EC2 instances remap EBS volumes to NVMe device
# names, and Azure/GCP have their own naming quirks. Instead, find the one
# disk with no partitions and no filesystem yet - on a freshly provisioned
# VM with exactly one extra disk attached, that's always the data disk.
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
