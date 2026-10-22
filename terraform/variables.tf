# --- Azure ---

variable "azure_location" {
  type        = string
  description = "Azure region for resources"
}

variable "azure_resource_group_name" {
  type        = string
  description = "Azure resource group name"
}

variable "azure_admin_username" {
  type        = string
  default     = "azureuser"
  description = "Admin username for the Azure SLES VMs"
}

variable "azure_ssh_public_key" {
  type        = string
  description = "SSH public key content for Azure VM access"
  default     = null # Optional fallback
}

# --- Rancher management cluster ---

variable "azure_rancher_vm_size" {
  type        = string
  default     = "Standard_D4s_v5"
  description = "Azure VM size for the Rancher management cluster nodes"
}

variable "rancher_node_count" {
  type        = number
  description = "Number of nodes in the Rancher management cluster. Can be 1 (standalone) or 3 (HA)."
  default     = 1

  validation {
    condition     = contains([1, 3], var.rancher_node_count)
    error_message = "The number of Rancher management cluster nodes must be 1 or 3."
  }
}

variable "rancher_hostname" {
  type        = string
  description = "FQDN for Rancher UI"
}

variable "rancher_bootstrap_password" {
  type        = string
  description = "The initial bootstrap password for the Rancher admin user."
  sensitive   = true
}

variable "rke2_token" {
  type        = string
  description = "Shared secret token used by Rancher management cluster nodes to join the RKE2 cluster"
  sensitive   = true
}

variable "rke2_version" {
  description = <<-EOT
    The version of RKE2 to install (e.g., v1.35.9+rke2r1). Defaults to the
    latest v1.35.x release rather than the overall latest RKE2 release, since
    starting with RKE2 v1.36, Traefik replaces ingress-nginx as the default
    packaged ingress controller. This project detects which one is in play
    from this version string (treating "" as the latest release, i.e. >= 1.36)
    and configures RKE2, cert-manager's ClusterIssuer, and the Rancher Helm
    chart to use the matching ingress controller automatically - no other
    changes are needed to move between them.
  EOT
  type        = string
  default     = "v1.35.9+rke2r1"
}

variable "cert_manager_version" {
  description = "The version of cert-manager to install."
  type        = string
  default     = "v1.13.1"
}

variable "rancher_version" {
  description = "The version of the Rancher Helm chart to install. If not set, the latest version from the Prime repository is used."
  type        = string
  default     = ""
}

variable "gemini_api_key" {
  type        = string
  description = "API Key for Google Gemini to be used by Rancher's AI Assistant 'Liz'."
  sensitive   = true
}

variable "gemini_model" {
  type        = string
  description = "The Google Gemini model to use for the Rancher AI Assistant."
  default     = "gemini-3-flash-preview"
}

# --- Downstream nodes ---

variable "azure_downstream_vm_size" {
  type        = string
  default     = "Standard_D4s_v5"
  description = "Azure VM size for the downstream RKE2/K3S SLES nodes"
}

variable "downstream_node_count" {
  type        = number
  description = "Number of downstream RKE2/K3S SLES nodes to provision."
  default     = 1
}

# --- SUSE registration & Customer Center ---

variable "sles_reg_code" {
  type        = string
  description = "SUSE Linux Enterprise Server Registration Code"
  sensitive   = true
}

variable "rancher_prime_reg_code" {
  type        = string
  description = "SUSE Customer Center Registration Code for Rancher Prime"
  sensitive   = true
}

variable "scc_username" {
  type        = string
  description = "Username for SUSE Customer Center API for de-registration on destroy. If not provided, de-registration is skipped."
  default     = null
  sensitive   = true
}

variable "scc_password" {
  type        = string
  description = "Password for SUSE Customer Center API for de-registration on destroy. If not provided, de-registration is skipped."
  default     = null
  sensitive   = true
}

# --- DNS (AWS Route53) ---

variable "domain_name" {
  type        = string
  description = "The base domain name for the deployment (e.g., mydomain.com)."
  default     = null
}

variable "aws_route53_zone_id" {
  type        = string
  description = "The Route53 Zone ID where the rancher hostname CNAME will be created."
  default     = null
}

variable "aws_create_route53_record" {
  type        = bool
  description = "If true, create a Route53 record for the Rancher hostname."
  default     = false
}

# --- TLS / Certificates ---

variable "use_letsencrypt" {
  description = "Set to true to use Let's Encrypt for the Rancher ingress certificate. Set to false to use a custom certificate from AWS Secrets Manager."
  type        = bool
  default     = true
}

variable "letsencrypt_email" {
  type        = string
  description = "Email address for Let's Encrypt certificates."
}

variable "aws_tls_cert_secret_arn" {
  description = "The ARN of the secret in AWS Secrets Manager containing the TLS certificate and key. Required if use_letsencrypt is false."
  type        = string
  default     = ""
}
