output "rancher_url" {
  description = "URL for the Rancher UI"
  value       = "https://${local.rancher_hostname}"
}

output "load_balancer_public_ip" {
  description = "Public IP address of the Azure Load Balancer fronting the Rancher management cluster"
  value       = azurerm_public_ip.lb_pip.ip_address
}

output "rancher_node_public_ips" {
  description = "Public IP addresses of the Rancher management cluster nodes, in node order (node 1 is the Rancher server)"
  value       = azurerm_public_ip.rancher_node_pip[*].ip_address
}

output "downstream_node_public_ips" {
  description = "Public IP addresses of the downstream nodes"
  value       = azurerm_public_ip.downstream_node_pip[*].ip_address
}

output "ssh_connection_commands" {
  description = "Ready-to-use SSH commands for each Rancher management node"
  value       = [for ip in azurerm_public_ip.rancher_node_pip[*].ip_address : "ssh ${var.azure_admin_username}@${ip}"]
}

output "kubeconfig_fetch_command" {
  description = "Command to retrieve the kubeconfig from the first Rancher node (rewrite the server address to the load balancer IP before using it remotely)"
  value       = "ssh ${var.azure_admin_username}@${azurerm_public_ip.rancher_node_pip[0].ip_address} sudo cat /etc/rancher/rke2/rke2.yaml"
}
