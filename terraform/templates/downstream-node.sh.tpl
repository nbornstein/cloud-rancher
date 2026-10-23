#!/bin/bash
set -euo pipefail

# Set the OS hostname (see first-node.sh.tpl for why this must come first).
hostnamectl set-hostname "${vm_hostname}"

# Register SLES using the registration code passed from Terraform
SUSEConnect -r "${sles_reg_code}"
SUSEConnect -p sle-module-public-cloud/15.7/x86_64
zypper --non-interactive --gpg-auto-import-keys refresh
zypper --non-interactive update -y
