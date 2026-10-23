# --- Cloud Provider Selection ---

variable "cloud_provider" {
  type        = string
  description = "Which cloud hosts the RKE2/Rancher VMs, VPC/VNet, and load balancer: \"azure\", \"aws\", or \"gcp\". Only the variable(s) for the selected provider need to be set. This is independent of the AWS provider used for Route53 DNS records and the Secrets Manager custom TLS cert option, both of which can be used regardless of which cloud hosts the VMs."
  default     = "azure"

  validation {
    condition     = contains(["azure", "aws", "gcp"], var.cloud_provider)
    error_message = "cloud_provider must be \"azure\", \"aws\", or \"gcp\"."
  }
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key content for VM/instance access, used regardless of cloud_provider."
  default     = null # Optional fallback to ~/.ssh/id_rsa.pub
}

# --- Azure ---

variable "azure_location" {
  type        = string
  description = "Azure region for resources. Required when cloud_provider = \"azure\"."
  default     = null
}

variable "azure_resource_group_name" {
  type        = string
  description = "Azure resource group name. Required when cloud_provider = \"azure\"."
  default     = null
}

variable "azure_admin_username" {
  type        = string
  default     = "azureuser"
  description = "Admin username for the Azure SLES VMs"
}

# --- AWS Compute (VPC, EC2, Load Balancer) ---
#
# Used when cloud_provider = "aws". Distinct from the aws_route53_* and
# aws_tls_cert_secret_arn variables below, which configure separate, optional
# AWS integrations (DNS and custom TLS certs) available regardless of
# cloud_provider.

variable "aws_region" {
  type        = string
  description = "AWS region for the VPC, EC2 instances, and load balancer. Required when cloud_provider = \"aws\". Resolved independently of the AWS provider used for Route53/Secrets Manager, which continues to use your AWS CLI/environment's default region."
  default     = null
}

variable "aws_vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC created for the RKE2 cluster."
  default     = "10.1.0.0/16"
}

variable "aws_admin_username" {
  type        = string
  description = "SSH login username for the AWS SLES AMI."
  default     = "ec2-user"
}

variable "aws_ami_id" {
  type        = string
  description = "AMI ID to use for the SLES 15 SP7 instances. Leave \"\" to auto-discover the latest SLES 15 SP7 BYOS AMI published by aws_sles_ami_owner_id in aws_region. Override this if that lookup picks the wrong image for your account/region - check with `aws ec2 describe-images --owners <aws_sles_ami_owner_id> --filters \"Name=name,Values=suse-sles-15-sp7-byos-v????????-hvm-ssd-x86_64-prod-*\"`."
  default     = ""
}

variable "aws_sles_ami_owner_id" {
  type        = string
  description = "AWS account ID that publishes the SLES AMIs used by the aws_ami_id auto-discovery lookup. Defaults to SUSE's current AWS Marketplace publishing account, verified directly with `aws ec2 describe-images --owners 679593333241 --filters \"Name=name,Values=suse-sles-15-sp7-byos*\"`. Only used when aws_ami_id is \"\"."
  default     = "679593333241"
}

# --- GCP Compute (VPC, Compute Engine, Load Balancer) ---
#
# Used when cloud_provider = "gcp". Distinct from the aws_route53_* and
# aws_tls_cert_secret_arn variables above, which configure separate, optional
# AWS integrations (DNS and custom TLS certs) available regardless of
# cloud_provider.

variable "gcp_project" {
  type        = string
  description = "GCP project ID to deploy into. Required when cloud_provider = \"gcp\"."
  default     = null
}

variable "gcp_region" {
  type        = string
  description = "GCP region for the VPC subnetwork and the regional load balancer resources. Required when cloud_provider = \"gcp\"."
  default     = null
}

variable "gcp_zone" {
  type        = string
  description = "GCP zone (within gcp_region) for the Compute Engine instances and the unmanaged instance group. Required when cloud_provider = \"gcp\"."
  default     = null
}

variable "gcp_subnet_cidr" {
  type        = string
  description = "CIDR block for the subnetwork created for the RKE2 cluster."
  default     = "10.2.0.0/24"
}

variable "gcp_admin_username" {
  type        = string
  description = "SSH login username pushed via instance metadata for the GCP SLES image. GCP has no baked-in default user - the guest agent creates whichever username is named in the ssh-keys metadata at boot."
  default     = "gcpuser"
}

variable "gcp_image_id" {
  type        = string
  description = "Self-link or image name to use for the SLES 15 SP7 instances. Leave \"\" to auto-discover the latest image in gcp_sles_image_family published by gcp_sles_image_project."
  default     = ""
}

variable "gcp_sles_image_family" {
  type        = string
  description = "GCP image family used by the gcp_image_id auto-discovery lookup. Verified directly with `gcloud compute images list --project=suse-byos-cloud --filter=\"family~sles-15-byos\"`. Only used when gcp_image_id is \"\"."
  default     = "sles-15-byos"
}

variable "gcp_sles_image_project" {
  type        = string
  description = "GCP project that publishes the SLES BYOS image family used by the gcp_image_id auto-discovery lookup."
  default     = "suse-byos-cloud"
}

# --- Rancher management cluster ---

variable "azure_rancher_vm_size" {
  type        = string
  default     = "Standard_D4s_v5"
  description = "Azure VM size for the Rancher management cluster nodes"
}

variable "aws_rancher_instance_type" {
  type        = string
  default     = "m5.xlarge"
  description = "EC2 instance type for the Rancher management cluster nodes"
}

variable "gcp_rancher_machine_type" {
  type        = string
  default     = "n2-standard-4"
  description = "GCE machine type for the Rancher management cluster nodes"
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
  description = "FQDN for Rancher UI. Required unless use_sslip_io is true, in which case it is derived automatically."
  default     = null
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

variable "aws_downstream_instance_type" {
  type        = string
  default     = "m5.xlarge"
  description = "EC2 instance type for the downstream RKE2/K3S SLES nodes"
}

variable "gcp_downstream_machine_type" {
  type        = string
  default     = "n2-standard-4"
  description = "GCE machine type for the downstream RKE2/K3S SLES nodes"
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

# --- DNS ---
#
# Three ways to get a hostname pointing at the Rancher Load Balancer:
#   1. AWS Route53 (aws_create_route53_record = true): Terraform creates the A record.
#   2. sslip.io (use_sslip_io = true): no record to create - the hostname is derived
#      from the Load Balancer's public IP and resolves automatically. No domain,
#      DNS provider, or AWS account needed.
#   3. Manual: set rancher_hostname and point it at the Load Balancer's public IP
#      yourself (output as load_balancer_public_ip) using whatever DNS you manage.

variable "domain_name" {
  type        = string
  description = "The base domain name for the deployment (e.g., YOUR_DOMAIN). Only used with Route53."
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

variable "use_sslip_io" {
  type        = bool
  description = "If true, skip rancher_hostname/DNS entirely and auto-generate a hostname from the Load Balancer's public IP using sslip.io (e.g. 20-1-2-3.sslip.io), which resolves to that IP with no DNS record to create or own domain required."
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
