terraform {
  required_version = ">= 1.3.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.80"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "azurerm" {
  features {}
}

provider "aws" {
  # Used for Route53 DNS records and the AWS Secrets Manager custom TLS cert
  # option, regardless of cloud_provider. Assumes you have AWS credentials
  # configured in your environment (e.g., via environment variables or
  # ~/.aws/credentials); region comes from that same environment/profile.
}

# A second, explicitly-regioned AWS provider for the VPC/EC2/load-balancer
# compute resources used when cloud_provider = "aws". Kept separate (via
# alias) from the provider above so Route53/Secrets Manager - which may
# legitimately target a different region - are unaffected by aws_region.
provider "aws" {
  alias  = "compute"
  region = coalesce(var.aws_region, "us-east-1")
}

# Used for the VPC/Compute Engine/load-balancer resources when cloud_provider = "gcp".
# GCP has no cross-cutting integration analogous to Route53/Secrets Manager competing
# for the default provider block, so a single unaliased block is sufficient here.
provider "google" {
  project = var.gcp_project
  region  = var.gcp_region
}

# Only hit the IP-echo service when the caller hasn't pinned allowed_admin_cidr_blocks
# themselves, since the lookup is an outbound call to a third party and is pointless
# once the list is explicit (e.g. ["0.0.0.0/0"] to reopen access).
data "http" "my_ip" {
  count = length(var.allowed_admin_cidr_blocks) == 0 ? 1 : 0

  url = "https://checkip.amazonaws.com"
}

locals {
  # CIDR blocks allowed to reach SSH/Kube-API/HTTPS on every cloud: either the
  # caller's explicit override, or the IP running `terraform apply`, auto-detected
  # so the apply-time health check in null_resource.wait_for_rancher (compute.tf)
  # always has a path in.
  admin_cidr_blocks = length(var.allowed_admin_cidr_blocks) > 0 ? var.allowed_admin_cidr_blocks : ["${chomp(data.http.my_ip[0].response_body)}/32"]
}

# Variable "validation" blocks can't reference other variables, so cross-variable
# requirements like "the right fields are set for the selected cloud_provider" use
# a resource precondition instead, which runs at plan time regardless of which
# cloud-specific resources it precedes.
resource "null_resource" "validate_cloud_provider_config" {
  lifecycle {
    precondition {
      condition = (
        (var.cloud_provider == "azure" &&
          var.azure_location != null && var.azure_location != "" &&
        var.azure_resource_group_name != null && var.azure_resource_group_name != "") ||
        (var.cloud_provider == "aws" &&
        var.aws_region != null && var.aws_region != "") ||
        (var.cloud_provider == "gcp" &&
          var.gcp_project != null && var.gcp_project != "" &&
          var.gcp_region != null && var.gcp_region != "" &&
        var.gcp_zone != null && var.gcp_zone != "")
      )
      error_message = "When cloud_provider = \"azure\", azure_location and azure_resource_group_name must be set. When cloud_provider = \"aws\", aws_region must be set. When cloud_provider = \"gcp\", gcp_project, gcp_region, and gcp_zone must be set."
    }
  }
}

resource "azurerm_resource_group" "rg" {
  count = var.cloud_provider == "azure" ? 1 : 0

  name     = var.azure_resource_group_name
  location = var.azure_location
}