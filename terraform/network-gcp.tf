resource "google_compute_network" "vpc" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name                    = "vpc-rke2-prod"
  auto_create_subnetworks = false
}

# A single subnet in one region, matching the single-subnet model used on the
# Azure/AWS sides (no multi-zone spread yet).
resource "google_compute_subnetwork" "subnet" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name          = "snet-rke2-nodes"
  network       = google_compute_network.vpc[0].id
  ip_cidr_range = var.gcp_subnet_cidr
  region        = var.gcp_region
}

resource "google_compute_firewall" "allow_rke2_admin" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name    = "fw-rke2-nodes-admin"
  network = google_compute_network.vpc[0].id

  allow {
    protocol = "tcp"
    ports    = ["22", "6443"]
  }

  source_ranges = local.admin_cidr_blocks
  target_tags   = ["rke2-node"]
}

resource "google_compute_firewall" "allow_rke2_http" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name    = "fw-rke2-nodes-http"
  network = google_compute_network.vpc[0].id

  allow {
    protocol = "tcp"
    # 80 is always open for the Let's Encrypt HTTP-01 challenge; 443 is always
    # open because Rancher's own TLS + auth protect it, and downstream
    # cluster agents/registration scripts connect from node IPs that have
    # nothing to do with wherever `terraform apply` was run.
    ports = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["rke2-node"]
}

# GCP VPC firewalls are default-deny with no implicit "same network" allow,
# unlike AWS security groups/Azure NSGs where traffic matching an explicit
# CIDR rule is allowed regardless of whether the source is internal or
# external. Without this rule, RKE2's inter-node traffic (the supervisor API
# on 9345 used by join-node.sh.tpl, kubelet, and the CNI overlay) would be
# blocked even between nodes in the same subnet.
resource "google_compute_firewall" "allow_internal" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name    = "fw-rke2-internal"
  network = google_compute_network.vpc[0].id

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  source_ranges = [var.gcp_subnet_cidr]
  target_tags   = ["rke2-node"]
}
