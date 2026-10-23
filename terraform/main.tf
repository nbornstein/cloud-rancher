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
        var.aws_region != null && var.aws_region != "")
      )
      error_message = "When cloud_provider = \"azure\", azure_location and azure_resource_group_name must be set. When cloud_provider = \"aws\", aws_region must be set."
    }
  }
}

resource "azurerm_resource_group" "rg" {
  count = var.cloud_provider == "azure" ? 1 : 0

  name     = var.azure_resource_group_name
  location = var.azure_location
}