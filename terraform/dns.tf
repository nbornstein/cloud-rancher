resource "aws_route53_record" "rancher_dns" {
  count = var.aws_create_route53_record && var.aws_route53_zone_id != null ? 1 : 0

  zone_id         = var.aws_route53_zone_id
  name            = var.rancher_hostname
  allow_overwrite = true
  type            = "A"
  ttl             = 300

  # Point the A record to the public IP of the Azure Load Balancer
  records = [azurerm_public_ip.lb_pip.ip_address]
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

  # Point the A record to the public IP of the corresponding Azure VM
  records = [azurerm_public_ip.rancher_node_pip[count.index].ip_address]
}

resource "aws_route53_record" "downstream_node_dns" {
  # Create one record for each downstream VM if aws_create_route53_record is true.
  count = var.aws_create_route53_record && var.aws_route53_zone_id != null && var.domain_name != null ? var.downstream_node_count : 0

  zone_id = var.aws_route53_zone_id
  # Creates downstream-node1.mydomain.com, downstream-node2.mydomain.com, etc.
  name            = "downstream-node${count.index + 1}.${var.domain_name}"
  allow_overwrite = true
  type            = "A"
  ttl             = 300

  # Point the A record to the public IP of the corresponding Azure VM
  records = [azurerm_public_ip.downstream_node_pip[count.index].ip_address]
}