# Auto-discover the latest SLES 15 SP7 BYOS image published in gcp_sles_image_family
# unless gcp_image_id overrides it. Must be the BYOS (Bring Your Own Subscription)
# family, not the plain/PAYG one: the boot script registers with SCC itself via
# `SUSEConnect -r var.sles_reg_code`, and doing that against a PAYG image - which
# auto-registers against SUSE's own update infrastructure at launch - creates
# registration conflicts.
# Verified directly against `gcloud compute images list --project=suse-byos-cloud`:
# the x86_64 BYOS family is "sles-15-byos" (not "sles-15-sp7-byos" - the "sp7"
# only appears in the image name, not the family, which tracks the latest SP
# automatically).
data "google_compute_image" "sles" {
  count = var.cloud_provider == "gcp" && var.gcp_image_id == "" ? 1 : 0

  family  = var.gcp_sles_image_family
  project = var.gcp_sles_image_project
}

locals {
  gcp_image_id = var.gcp_image_id != "" ? var.gcp_image_id : (length(data.google_compute_image.sles) > 0 ? data.google_compute_image.sles[0].self_link : "")

  gcp_ssh_metadata = {
    ssh-keys = "${var.gcp_admin_username}:${var.ssh_public_key != null ? var.ssh_public_key : file("~/.ssh/id_rsa.pub")}"
  }
}

# --- Rancher Management Cluster Nodes ---

# Reserved ahead of the instance, for two reasons: it gives outputs.tf/SSH
# commands a stable IP independent of instance creation (matching the
# AWS EIP/Azure Public IP pattern), and it's the GCP-idiomatic way around the
# same self-reference problem AWS solves with a separate network interface:
# referencing google_compute_instance.rancher_vm[0]'s own attribute from
# within that same counted resource's own config (for join-node.sh.tpl's
# first_node_ip on nodes > 0) is a self-referential block Terraform rejects.
resource "google_compute_address" "rancher_node_internal_ip" {
  count = var.cloud_provider == "gcp" ? var.rancher_node_count : 0

  name         = "ip-int-rancher-node-${count.index + 1}"
  region       = var.gcp_region
  subnetwork   = google_compute_subnetwork.subnet[0].id
  address_type = "INTERNAL"
}

resource "google_compute_address" "rancher_node_external_ip" {
  count = var.cloud_provider == "gcp" ? var.rancher_node_count : 0

  name         = "ip-ext-rancher-node-${count.index + 1}"
  region       = var.gcp_region
  address_type = "EXTERNAL"
}

resource "google_compute_instance" "rancher_vm" {
  count = var.cloud_provider == "gcp" ? var.rancher_node_count : 0

  name         = "vm-rancher-node-${count.index + 1}"
  zone         = var.gcp_zone
  machine_type = var.gcp_rancher_machine_type
  tags         = ["rke2-node"]

  # Same ordering reason as the Azure/AWS VMs' depends_on: the first node's
  # boot script requests a Let's Encrypt certificate via HTTP-01 against
  # rancher_hostname, which needs the Route53 record (if any) to exist first.
  depends_on = [aws_route53_record.rancher_dns]

  boot_disk {
    initialize_params {
      image = local.gcp_image_id
      size  = 80
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet[0].id
    network_ip = google_compute_address.rancher_node_internal_ip[count.index].address

    access_config {
      nat_ip = google_compute_address.rancher_node_external_ip[count.index].address
    }
  }

  metadata = local.gcp_ssh_metadata

  metadata_startup_script = (
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
      ai_ui_extension_version    = var.ai_ui_extension_version,
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
      app_collection_username    = var.app_collection_username,
      app_collection_password    = var.app_collection_password,
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
      first_node_ip    = google_compute_address.rancher_node_internal_ip[0].address,
      rancher_hostname = local.rancher_hostname
    })
  )
}

# --- Downstream Nodes ---

resource "google_compute_address" "downstream_node_external_ip" {
  count = var.cloud_provider == "gcp" ? var.downstream_node_count : 0

  name         = "ip-ext-downstream-node-${count.index + 1}"
  region       = var.gcp_region
  address_type = "EXTERNAL"
}

resource "google_compute_instance" "downstream_vm" {
  count = var.cloud_provider == "gcp" ? var.downstream_node_count : 0

  name         = "vm-downstream-node-${count.index + 1}"
  zone         = var.gcp_zone
  machine_type = var.gcp_downstream_machine_type
  tags         = ["rke2-node"]

  boot_disk {
    initialize_params {
      image = local.gcp_image_id
      size  = 80
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet[0].id

    access_config {
      nat_ip = google_compute_address.downstream_node_external_ip[count.index].address
    }
  }

  dynamic "attached_disk" {
    for_each = var.install_suse_storage ? [google_compute_disk.downstream_storage[count.index].id] : []
    content {
      source = attached_disk.value
    }
  }

  metadata = local.gcp_ssh_metadata

  metadata_startup_script = templatefile("${path.module}/templates/downstream-node.sh.tpl", {
    vm_hostname          = "vm-downstream-node-${count.index + 1}",
    sles_reg_code        = var.sles_reg_code,
    install_suse_storage = var.install_suse_storage
  })
}

# A dedicated 40G data disk for SUSE Storage (Longhorn), the block-storage
# prerequisite for SUSE AI Factory. See compute-aws.tf's downstream_storage
# comment for why this is a separate disk from the OS disk.
resource "google_compute_disk" "downstream_storage" {
  count = var.cloud_provider == "gcp" && var.install_suse_storage ? var.downstream_node_count : 0

  name = "disk-downstream-storage-${count.index + 1}"
  zone = var.gcp_zone
  size = 40
  type = "pd-ssd"
}
