# A regional, backend-service-based external passthrough Network Load Balancer,
# mirroring the AWS NLB's 3 target-groups/3 listeners/1 shared IP shape (chosen
# over GCP's legacy target-pool LB, which doesn't support per-port health checks).

# External addresses can be referenced by multiple forwarding rules as long as
# the rules don't collide on (protocol, port) - no special purpose needed here
# (that's only for INTERNAL addresses). This is the GCP equivalent of the AWS
# NLB exposing all 3 ports through a single EIP via subnet_mapping.
resource "google_compute_address" "lb_ip" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name         = "ip-rancher-lb"
  region       = var.gcp_region
  address_type = "EXTERNAL"
}

# Replaces AWS's per-port aws_lb_target_group_attachment resources: one
# unmanaged instance group listing every rancher node, with a named port per
# service port for the backend services below to reference.
resource "google_compute_instance_group" "rancher_ig" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name = "ig-rancher-cluster"
  zone = var.gcp_zone

  instances = google_compute_instance.rancher_vm[*].self_link

  named_port {
    name = "kube-api"
    port = 6443
  }

  named_port {
    name = "http"
    port = 80
  }

  named_port {
    name = "https"
    port = 443
  }
}

# Health checks + backend services + forwarding rules (6443 Kube-API, 80 HTTP,
# 443 HTTPS), mirroring the AWS target groups' TCP health checks and listeners.
resource "google_compute_region_health_check" "hc_6443" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name   = "hc-rancher-6443"
  region = var.gcp_region

  tcp_health_check {
    port = 6443
  }
}

resource "google_compute_region_health_check" "hc_80" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name   = "hc-rancher-80"
  region = var.gcp_region

  tcp_health_check {
    port = 80
  }
}

resource "google_compute_region_health_check" "hc_443" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name   = "hc-rancher-443"
  region = var.gcp_region

  tcp_health_check {
    port = 443
  }
}

resource "google_compute_region_backend_service" "bs_6443" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name                  = "bs-rancher-6443"
  region                = var.gcp_region
  protocol              = "TCP"
  load_balancing_scheme = "EXTERNAL"
  health_checks         = [google_compute_region_health_check.hc_6443[0].id]

  backend {
    group          = google_compute_instance_group.rancher_ig[0].id
    balancing_mode = "CONNECTION"
  }
}

resource "google_compute_region_backend_service" "bs_80" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name                  = "bs-rancher-80"
  region                = var.gcp_region
  protocol              = "TCP"
  load_balancing_scheme = "EXTERNAL"
  health_checks         = [google_compute_region_health_check.hc_80[0].id]

  backend {
    group          = google_compute_instance_group.rancher_ig[0].id
    balancing_mode = "CONNECTION"
  }
}

resource "google_compute_region_backend_service" "bs_443" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name                  = "bs-rancher-443"
  region                = var.gcp_region
  protocol              = "TCP"
  load_balancing_scheme = "EXTERNAL"
  health_checks         = [google_compute_region_health_check.hc_443[0].id]

  backend {
    group          = google_compute_instance_group.rancher_ig[0].id
    balancing_mode = "CONNECTION"
  }
}

resource "google_compute_forwarding_rule" "fwd_6443" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name                  = "fwd-rancher-6443"
  region                = var.gcp_region
  ip_address            = google_compute_address.lb_ip[0].address
  ip_protocol           = "TCP"
  port_range            = "6443"
  load_balancing_scheme = "EXTERNAL"
  backend_service       = google_compute_region_backend_service.bs_6443[0].id
}

resource "google_compute_forwarding_rule" "fwd_80" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name                  = "fwd-rancher-80"
  region                = var.gcp_region
  ip_address            = google_compute_address.lb_ip[0].address
  ip_protocol           = "TCP"
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL"
  backend_service       = google_compute_region_backend_service.bs_80[0].id
}

resource "google_compute_forwarding_rule" "fwd_443" {
  count = var.cloud_provider == "gcp" ? 1 : 0

  name                  = "fwd-rancher-443"
  region                = var.gcp_region
  ip_address            = google_compute_address.lb_ip[0].address
  ip_protocol           = "TCP"
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL"
  backend_service       = google_compute_region_backend_service.bs_443[0].id
}
