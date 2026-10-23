output "rancher_url" {
  description = "URL for the Rancher UI"
  value       = "https://${local.rancher_hostname}"
}

output "load_balancer_public_ip" {
  description = "Public IP address of the cloud load balancer fronting the Rancher management cluster"
  value       = local.lb_public_ip
}

output "rancher_node_public_ips" {
  description = "Public IP addresses of the Rancher management cluster nodes, in node order (node 1 is the Rancher server)"
  value       = local.rancher_node_public_ips
}

output "downstream_node_public_ips" {
  description = "Public IP addresses of the downstream nodes"
  value       = local.downstream_node_public_ips
}

output "ssh_connection_commands" {
  description = "Ready-to-use SSH commands for each Rancher management node"
  value       = [for ip in local.rancher_node_public_ips : "ssh ${local.admin_username}@${ip}"]
}

output "kubeconfig_fetch_command" {
  description = "Command to retrieve the kubeconfig from the first Rancher node (rewrite the server address to the load balancer IP before using it remotely)"
  value       = "ssh ${local.admin_username}@${local.rancher_node_public_ips[0]} sudo cat /etc/rancher/rke2/rke2.yaml"
}
