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

# --- AI Assistant (Rancher AI "Liz") ---

variable "ai_llm_provider" {
  type        = string
  description = "Which LLM backend powers the Rancher AI Assistant (Liz): gemini, openai, bedrock, ollama, or generic-openai. Leave as \"\" (the default) to skip installing the AI Assistant entirely. Only the variable(s) for the selected provider need to be set."
  default     = ""

  validation {
    condition     = contains(["", "gemini", "openai", "bedrock", "ollama", "generic-openai"], var.ai_llm_provider)
    error_message = "ai_llm_provider must be \"\" (disabled) or one of: gemini, openai, bedrock, ollama, generic-openai."
  }
}

variable "gemini_api_key" {
  type        = string
  description = "API key for Google Gemini. Required when ai_llm_provider = \"gemini\"."
  default     = null
  sensitive   = true
}

variable "gemini_model" {
  type        = string
  description = "The Google Gemini model to use for the Rancher AI Assistant."
  default     = "gemini-3-flash-preview"
}

variable "openai_api_key" {
  type        = string
  description = "API key for OpenAI. Required when ai_llm_provider = \"openai\"."
  default     = null
  sensitive   = true
}

variable "openai_model" {
  type        = string
  description = "The OpenAI model to use for the Rancher AI Assistant."
  default     = "gpt-4o"
}

variable "bedrock_model" {
  type        = string
  description = "The AWS Bedrock model to use for the Rancher AI Assistant."
  default     = "global.anthropic.claude-opus-4-5-20251101-v1:0"
}

variable "bedrock_bearer_token" {
  type        = string
  description = "Bearer token for AWS Bedrock. Required when ai_llm_provider = \"bedrock\"."
  default     = null
  sensitive   = true
}

variable "bedrock_region" {
  type        = string
  description = "AWS region of the Bedrock model. Required when ai_llm_provider = \"bedrock\"."
  default     = "us-east-1"
}

variable "bedrock_url" {
  type        = string
  description = "Optional custom Bedrock endpoint URL (e.g. a VPC endpoint). Leave blank to use the default AWS Bedrock endpoint."
  default     = ""
}

variable "ollama_model" {
  type        = string
  description = "The Ollama model to use for the Rancher AI Assistant."
  default     = "gpt-oss:120b"
}

variable "ollama_url" {
  type        = string
  description = "URL of the Ollama server. Required when ai_llm_provider = \"ollama\"."
  default     = "http://ollama:11434"
}

variable "generic_openai_model" {
  type        = string
  description = "The model name to use with the generic OpenAI-compatible endpoint. Required when ai_llm_provider = \"generic-openai\"."
  default     = ""
}

variable "generic_openai_url" {
  type        = string
  description = "URL of the OpenAI-compatible endpoint (e.g. Azure OpenAI, vLLM). Required when ai_llm_provider = \"generic-openai\"."
  default     = ""
}

variable "generic_openai_api_key" {
  type        = string
  description = "API key for the generic OpenAI-compatible endpoint. Required when ai_llm_provider = \"generic-openai\"."
  default     = null
  sensitive   = true
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
