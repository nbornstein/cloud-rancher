locals {
  # sslip.io resolves "<ip-with-dashes>.sslip.io" to that IP automatically - no record
  # to create or wait on. Used in place of var.rancher_hostname everywhere a hostname
  # is needed, so the rest of the config doesn't care which DNS option was chosen.
  sslip_hostname   = "${replace(local.lb_public_ip, ".", "-")}.sslip.io"
  rancher_hostname = var.use_sslip_io ? local.sslip_hostname : var.rancher_hostname
}

resource "null_resource" "validate_dns_config" {
  lifecycle {
    precondition {
      condition     = var.use_sslip_io || (var.rancher_hostname != null && var.rancher_hostname != "")
      error_message = "Set rancher_hostname (used with Route53 or manually-managed DNS), or set use_sslip_io = true to auto-generate one from the Load Balancer's public IP via sslip.io."
    }
  }
}

resource "aws_route53_record" "rancher_dns" {
  count = var.aws_create_route53_record && var.aws_route53_zone_id != null ? 1 : 0

  zone_id         = var.aws_route53_zone_id
  name            = local.rancher_hostname
  allow_overwrite = true
  type            = "A"
  ttl             = 300

  # Point the A record to the public IP of the cloud load balancer
  records = [local.lb_public_ip]
}

resource "aws_route53_record" "rancher_node_dns" {
  # Create one record for each VM if aws_create_route53_record is true.
  count = var.aws_create_route53_record && var.aws_route53_zone_id != null && var.domain_name != null ? var.rancher_node_count : 0

  zone_id = var.aws_route53_zone_id
  # Creates rancher-node1.suse-southeast.com, rancher-node2.suse-southeast.com, etc.
  name            = "rancher-node${count.index + 1}.${var.domain_name}"
  allow_overwrite = true
  type            = "A"
  ttl             = 300

  # Point the A record to the public IP of the corresponding VM
  records = [local.rancher_node_public_ips[count.index]]
}

resource "aws_route53_record" "downstream_node_dns" {
  # Create one record for each downstream VM if aws_create_route53_record is true.
  count = var.aws_create_route53_record && var.aws_route53_zone_id != null && var.domain_name != null ? var.downstream_node_count : 0

  zone_id = var.aws_route53_zone_id
  # Creates downstream-node1.YOUR_DOMAIN, downstream-node2.YOUR_DOMAIN, etc.
  name            = "downstream-node${count.index + 1}.${var.domain_name}"
  allow_overwrite = true
  type            = "A"
  ttl             = 300

  # Point the A record to the public IP of the corresponding VM
  records = [local.downstream_node_public_ips[count.index]]
}