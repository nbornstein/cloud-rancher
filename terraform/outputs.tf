output "rancher_url" {
  description = "URL for the Rancher UI"
  value       = "https://${var.rancher_hostname}"
}

output "load_balancer_public_ip" {
  description = "Public IP address of the Azure Load Balancer fronting the RKE2 management cluster"
  value       = azurerm_public_ip.lb_pip.ip_address
}

output "rke2_node_public_ips" {
  description = "Public IP addresses of the RKE2 management cluster nodes, in node order (node 1 is the Rancher server)"
  value       = azurerm_public_ip.node_pip[*].ip_address
}

output "downstream_node_public_ips" {
  description = "Public IP addresses of the downstream nodes"
  value       = azurerm_public_ip.downstream_node_pip[*].ip_address
}

output "ssh_connection_commands" {
  description = "Ready-to-use SSH commands for each RKE2 management node"
  value       = [for ip in azurerm_public_ip.node_pip[*].ip_address : "ssh ${var.admin_username}@${ip}"]
}

output "kubeconfig_fetch_command" {
  description = "Command to retrieve the kubeconfig from the first RKE2 node (rewrite the server address to the load balancer IP before using it remotely)"
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.node_pip[0].ip_address} sudo cat /etc/rancher/rke2/rke2.yaml"
}
