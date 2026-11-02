resource "aws_key_pair" "ssh_key" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider   = aws.compute
  key_name   = "kp-rke2"
  public_key = var.ssh_public_key != null ? var.ssh_public_key : file("~/.ssh/id_rsa.pub")
}

# Auto-discover the latest SLES 15 SP7 BYOS AMI published by aws_sles_ami_owner_id
# unless aws_ami_id overrides it. Must be the BYOS (Bring Your Own Subscription)
# image, not the plain/PAYG one: the boot script registers with SCC itself via
# `SUSEConnect -r var.sles_reg_code`, and doing that against a PAYG image - which
# auto-registers against SUSE's own update infrastructure at launch - creates
# registration conflicts.
# Verified directly against `aws ec2 describe-images` (SUSE's public image tracker,
# pint.suse.com, lists an owner ID that turned out to be wrong - 013907871322 is
# stale/inactive for this image as of 2026-10). The real publishing account also
# appends a random per-build Marketplace product-code suffix to the name (e.g.
# "...-x86_64-prod-v6etgxzep2nwu"), hence the trailing "-prod-*".
# The date portion of the version uses "?" (exactly one char) rather than "*": with
# "*" there, it would also match other date-adjacent variants (e.g. "-ecs-") that
# "most_recent" could then pick over the plain BYOS image we actually want.
data "aws_ami" "sles" {
  count = var.cloud_provider == "aws" && var.aws_ami_id == "" ? 1 : 0

  provider    = aws.compute
  most_recent = true
  owners      = [var.aws_sles_ami_owner_id]

  filter {
    name   = "name"
    values = ["suse-sles-15-sp7-byos-v????????-hvm-ssd-x86_64-prod-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  aws_ami_id = var.aws_ami_id != "" ? var.aws_ami_id : (length(data.aws_ami.sles) > 0 ? data.aws_ami.sles[0].id : "")
}

# --- Rancher Management Cluster Nodes ---

resource "aws_eip" "rancher_node_eip" {
  count = var.cloud_provider == "aws" ? var.rancher_node_count : 0

  provider = aws.compute
  domain   = "vpc"

  tags = {
    Name = "eip-rancher-node-${count.index + 1}"
  }
}

# A dedicated NIC per rancher node, purely so join-node instances can read node 0's
# private IP (for "server: https://<ip>:9345" in their RKE2 config) from a resource
# other than aws_instance.rancher_vm itself: referencing aws_instance.rancher_vm[0]
# from within aws_instance.rancher_vm's own user_data is a self-referential block,
# which Terraform rejects even though count.index == 0 makes it reachable only for
# the one instance that isn't self-referencing. Mirrors the Azure side, where the
# same private IP already comes from azurerm_network_interface, a separate resource.
resource "aws_network_interface" "rancher_nic" {
  count = var.cloud_provider == "aws" ? var.rancher_node_count : 0

  provider        = aws.compute
  subnet_id       = aws_subnet.subnet[0].id
  security_groups = [aws_security_group.nsg[0].id]

  tags = {
    Name = "nic-rancher-node-${count.index + 1}"
  }
}

resource "aws_instance" "rancher_vm" {
  count = var.cloud_provider == "aws" ? var.rancher_node_count : 0

  provider      = aws.compute
  ami           = local.aws_ami_id
  instance_type = var.aws_rancher_instance_type
  key_name      = aws_key_pair.ssh_key[0].key_name

  network_interface {
    network_interface_id = aws_network_interface.rancher_nic[count.index].id
    device_index         = 0
  }

  # Same ordering reason as the Azure VM's depends_on: the first node's boot
  # script requests a Let's Encrypt certificate via HTTP-01 against
  # rancher_hostname, which needs the Route53 record (if any) to exist first.
  depends_on = [aws_route53_record.rancher_dns]

  root_block_device {
    volume_size = 80
    volume_type = "gp3"
  }

  tags = {
    Name = "vm-rancher-node-${count.index + 1}"
  }

  # Gzipped rather than plain base64: the rendered script (especially with
  # custom TLS certs/CA embedded, not Let's Encrypt) exceeds AWS's 25600-byte
  # encoded user-data limit otherwise. EC2's cloud-init auto-detects gzip and
  # decompresses it before running, so this is transparent at boot.
  user_data_base64 = base64gzip(
    count.index == 0 ?
    templatefile("${path.module}/templates/first-node.sh.tpl", {
      vm_hostname                  = "vm-rancher-node-${count.index + 1}",
      sles_reg_code                = var.sles_reg_code,
      rancher_prime_reg_code       = var.rancher_prime_reg_code,
      rke2_token                   = var.rke2_token,
      lb_ip                        = local.lb_public_ip,
      rancher_hostname             = local.rancher_hostname,
      rancher_bootstrap_password   = var.rancher_bootstrap_password,
      letsencrypt_email            = var.letsencrypt_email,
      ai_llm_provider              = var.ai_llm_provider,
      ai_ui_extension_version      = var.ai_ui_extension_version,
      gemini_api_key               = var.gemini_api_key,
      gemini_model                 = var.gemini_model,
      openai_api_key               = var.openai_api_key,
      openai_model                 = var.openai_model,
      bedrock_model                = var.bedrock_model,
      bedrock_bearer_token         = var.bedrock_bearer_token,
      bedrock_region               = var.bedrock_region,
      bedrock_url                  = var.bedrock_url,
      ollama_model                 = var.ollama_model,
      ollama_url                   = var.ollama_url,
      generic_openai_model         = var.generic_openai_model,
      generic_openai_url           = var.generic_openai_url,
      generic_openai_api_key       = var.generic_openai_api_key,
      app_collection_username      = var.app_collection_username,
      app_collection_password      = var.app_collection_password,
      use_letsencrypt              = var.use_letsencrypt,
      tls_cert_b64                 = local.tls_cert_b64,
      tls_key_b64                  = local.tls_key_b64,
      ca_cert_b64                  = local.ca_cert_b64,
      rke2_version                 = var.rke2_version,
      rke2_ingress_controller      = local.rke2_ingress_controller,
      ingress_daemonset_name       = local.ingress_daemonset_name,
      ingress_class_name           = local.ingress_class_name,
      cert_manager_version         = var.cert_manager_version,
      rancher_version              = var.rancher_version,
      install_ai_factory           = var.install_ai_factory,
      ai_factory_fleet_repo_url    = var.ai_factory_fleet_repo_url,
      ai_factory_fleet_repo_branch = var.ai_factory_fleet_repo_branch
    }) :
    templatefile("${path.module}/templates/join-node.sh.tpl", {
      vm_hostname      = "vm-rancher-node-${count.index + 1}",
      sles_reg_code    = var.sles_reg_code,
      rke2_token       = var.rke2_token,
      rke2_version     = var.rke2_version,
      lb_ip            = local.lb_public_ip,
      first_node_ip    = aws_network_interface.rancher_nic[0].private_ip,
      rancher_hostname = local.rancher_hostname
    })
  )
}

resource "aws_eip_association" "rancher_node_eip_assoc" {
  count = var.cloud_provider == "aws" ? var.rancher_node_count : 0

  provider      = aws.compute
  instance_id   = aws_instance.rancher_vm[count.index].id
  allocation_id = aws_eip.rancher_node_eip[count.index].id
}

resource "aws_lb_target_group_attachment" "rancher_tg_6443" {
  count = var.cloud_provider == "aws" ? var.rancher_node_count : 0

  provider         = aws.compute
  target_group_arn = aws_lb_target_group.tg_6443[0].arn
  target_id        = aws_instance.rancher_vm[count.index].id
  port             = 6443
}

resource "aws_lb_target_group_attachment" "rancher_tg_80" {
  count = var.cloud_provider == "aws" ? var.rancher_node_count : 0

  provider         = aws.compute
  target_group_arn = aws_lb_target_group.tg_80[0].arn
  target_id        = aws_instance.rancher_vm[count.index].id
  port             = 80
}

resource "aws_lb_target_group_attachment" "rancher_tg_443" {
  count = var.cloud_provider == "aws" ? var.rancher_node_count : 0

  provider         = aws.compute
  target_group_arn = aws_lb_target_group.tg_443[0].arn
  target_id        = aws_instance.rancher_vm[count.index].id
  port             = 443
}

# --- Downstream Nodes ---

resource "aws_eip" "downstream_node_eip" {
  count = var.cloud_provider == "aws" ? var.downstream_node_count : 0

  provider = aws.compute
  domain   = "vpc"

  tags = {
    Name = "eip-downstream-node-${count.index + 1}"
  }
}

resource "aws_instance" "downstream_vm" {
  count = var.cloud_provider == "aws" ? var.downstream_node_count : 0

  provider               = aws.compute
  ami                    = local.aws_ami_id
  instance_type          = var.aws_downstream_instance_type
  subnet_id              = aws_subnet.subnet[0].id
  vpc_security_group_ids = [aws_security_group.nsg[0].id]
  key_name               = aws_key_pair.ssh_key[0].key_name

  root_block_device {
    volume_size = 80
    volume_type = "gp3"
  }

  tags = {
    Name = "vm-downstream-node-${count.index + 1}"
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/downstream-node.sh.tpl", {
    vm_hostname          = "vm-downstream-node-${count.index + 1}",
    sles_reg_code        = var.sles_reg_code,
    install_suse_storage = var.install_suse_storage
  }))
}

resource "aws_eip_association" "downstream_node_eip_assoc" {
  count = var.cloud_provider == "aws" ? var.downstream_node_count : 0

  provider      = aws.compute
  instance_id   = aws_instance.downstream_vm[count.index].id
  allocation_id = aws_eip.downstream_node_eip[count.index].id
}

# A dedicated 40G data disk for SUSE Storage (Longhorn), the block-storage
# prerequisite for SUSE AI Factory. Kept separate from the 80G root disk so
# Longhorn gets its own device to claim, mirroring how it's deployed in
# practice (a disk reserved for its data path, not sharing the OS disk).
resource "aws_ebs_volume" "downstream_storage" {
  count = var.cloud_provider == "aws" && var.install_suse_storage ? var.downstream_node_count : 0

  provider          = aws.compute
  availability_zone = aws_instance.downstream_vm[count.index].availability_zone
  size              = 40
  type              = "gp3"

  tags = {
    Name = "vol-downstream-storage-${count.index + 1}"
  }
}

resource "aws_volume_attachment" "downstream_storage_attach" {
  count = var.cloud_provider == "aws" && var.install_suse_storage ? var.downstream_node_count : 0

  provider    = aws.compute
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.downstream_storage[count.index].id
  instance_id = aws_instance.downstream_vm[count.index].id
}

# --- SUSE AI Factory Cluster Nodes ---
#
# A separate, GPU-enabled downstream RKE2 cluster from the plain downstream
# nodes above - its own VM/disk/network resources, auto-installing and
# self-registering with Rancher rather than sitting idle for manual
# registration. See rancher.tf for the Rancher-side registration.

resource "aws_eip" "ai_factory_node_eip" {
  count = var.cloud_provider == "aws" && var.install_ai_factory ? var.ai_factory_node_count : 0

  provider = aws.compute
  domain   = "vpc"

  tags = {
    Name = "eip-ai-factory-node-${count.index + 1}"
  }
}

# Same self-reference workaround as aws_network_interface.rancher_nic above:
# join nodes need node 0's private IP from a resource other than
# aws_instance.ai_factory_vm itself.
resource "aws_network_interface" "ai_factory_nic" {
  count = var.cloud_provider == "aws" && var.install_ai_factory ? var.ai_factory_node_count : 0

  provider        = aws.compute
  subnet_id       = aws_subnet.subnet[0].id
  security_groups = [aws_security_group.nsg[0].id]

  tags = {
    Name = "nic-ai-factory-node-${count.index + 1}"
  }
}

resource "aws_instance" "ai_factory_vm" {
  count = var.cloud_provider == "aws" && var.install_ai_factory ? var.ai_factory_node_count : 0

  provider      = aws.compute
  ami           = local.aws_ami_id
  instance_type = var.aws_downstream_gpu_instance_type
  key_name      = aws_key_pair.ssh_key[0].key_name

  network_interface {
    network_interface_id = aws_network_interface.ai_factory_nic[count.index].id
    device_index         = 0
  }

  root_block_device {
    volume_size = 80
    volume_type = "gp3"
  }

  tags = {
    Name = "vm-ai-factory-node-${count.index + 1}"
  }

  user_data_base64 = base64gzip(
    count.index == 0 ?
    templatefile("${path.module}/templates/downstream-first-node.sh.tpl", {
      vm_hostname               = "vm-ai-factory-node-${count.index + 1}",
      sles_reg_code             = var.sles_reg_code,
      downstream_rke2_token     = var.downstream_rke2_token,
      downstream_rke2_version   = var.downstream_rke2_version != "" ? var.downstream_rke2_version : var.rke2_version,
      install_suse_storage      = true,
      registration_manifest_url = rancher2_cluster.ai_factory[0].cluster_registration_token[0].manifest_url,
    }) :
    templatefile("${path.module}/templates/downstream-join-node.sh.tpl", {
      vm_hostname             = "vm-ai-factory-node-${count.index + 1}",
      sles_reg_code           = var.sles_reg_code,
      downstream_rke2_token   = var.downstream_rke2_token,
      downstream_rke2_version = var.downstream_rke2_version != "" ? var.downstream_rke2_version : var.rke2_version,
      first_node_ip           = aws_network_interface.ai_factory_nic[0].private_ip,
      install_suse_storage    = true,
    })
  )
}

resource "aws_eip_association" "ai_factory_node_eip_assoc" {
  count = var.cloud_provider == "aws" && var.install_ai_factory ? var.ai_factory_node_count : 0

  provider      = aws.compute
  instance_id   = aws_instance.ai_factory_vm[count.index].id
  allocation_id = aws_eip.ai_factory_node_eip[count.index].id
}

# A dedicated 40G data disk for SUSE Storage (Longhorn) on every AI Factory
# node - unlike install_suse_storage on plain downstream nodes, this is
# always attached (not conditional) since SUSE AI Factory always needs it.
resource "aws_ebs_volume" "ai_factory_storage" {
  count = var.cloud_provider == "aws" && var.install_ai_factory ? var.ai_factory_node_count : 0

  provider          = aws.compute
  availability_zone = aws_instance.ai_factory_vm[count.index].availability_zone
  size              = 40
  type              = "gp3"

  tags = {
    Name = "vol-ai-factory-storage-${count.index + 1}"
  }
}

resource "aws_volume_attachment" "ai_factory_storage_attach" {
  count = var.cloud_provider == "aws" && var.install_ai_factory ? var.ai_factory_node_count : 0

  provider    = aws.compute
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.ai_factory_storage[count.index].id
  instance_id = aws_instance.ai_factory_vm[count.index].id
}
