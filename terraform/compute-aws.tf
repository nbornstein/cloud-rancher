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

  user_data_base64 = base64encode(
    count.index == 0 ?
    templatefile("${path.module}/templates/first-node.sh.tpl", {
      vm_hostname                = "vm-rancher-node-${count.index + 1}",
      sles_reg_code              = var.sles_reg_code,
      rancher_prime_reg_code     = var.rancher_prime_reg_code,
      rke2_token                 = var.rke2_token,
      lb_ip                      = local.lb_public_ip,
      rancher_hostname           = local.rancher_hostname,
      rancher_bootstrap_password = var.rancher_bootstrap_password,
      letsencrypt_email          = var.letsencrypt_email,
      ai_llm_provider            = var.ai_llm_provider,
      gemini_api_key             = var.gemini_api_key,
      gemini_model               = var.gemini_model,
      openai_api_key             = var.openai_api_key,
      openai_model               = var.openai_model,
      bedrock_model              = var.bedrock_model,
      bedrock_bearer_token       = var.bedrock_bearer_token,
      bedrock_region             = var.bedrock_region,
      bedrock_url                = var.bedrock_url,
      ollama_model               = var.ollama_model,
      ollama_url                 = var.ollama_url,
      generic_openai_model       = var.generic_openai_model,
      generic_openai_url         = var.generic_openai_url,
      generic_openai_api_key     = var.generic_openai_api_key,
      use_letsencrypt            = var.use_letsencrypt,
      tls_cert_b64               = local.tls_cert_b64,
      tls_key_b64                = local.tls_key_b64,
      ca_cert_b64                = local.ca_cert_b64,
      rke2_version               = var.rke2_version,
      rke2_ingress_controller    = local.rke2_ingress_controller,
      ingress_daemonset_name     = local.ingress_daemonset_name,
      ingress_class_name         = local.ingress_class_name,
      cert_manager_version       = var.cert_manager_version,
      rancher_version            = var.rancher_version
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

  user_data_base64 = base64encode(templatefile("${path.module}/templates/downstream-node.sh.tpl", {
    vm_hostname   = "vm-downstream-node-${count.index + 1}",
    sles_reg_code = var.sles_reg_code
  }))
}

resource "aws_eip_association" "downstream_node_eip_assoc" {
  count = var.cloud_provider == "aws" ? var.downstream_node_count : 0

  provider      = aws.compute
  instance_id   = aws_instance.downstream_vm[count.index].id
  allocation_id = aws_eip.downstream_node_eip[count.index].id
}
