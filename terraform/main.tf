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
    rancher2 = {
      source  = "rancher/rancher2"
      version = "~> 5.1"
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

# Used only when install_ai_factory = true, to auto-register the SUSE AI
# Factory downstream cluster with this Rancher management cluster (see
# rancher.tf). This is a two-phase setup: the "bootstrap" provider below logs
# in with rancher_bootstrap_password (the same password the Rancher Helm
# install on the management cluster was configured with) just long enough to
# mint a real admin API token via rancher2_bootstrap, which the "admin"
# provider then uses for everything else. Both point at the same Rancher
# instance; api_url is built from local.rancher_hostname (dns.tf) rather than
# reading outputs.tf's "rancher_url" output, since outputs aren't addressable
# from provider blocks within the same module.
provider "rancher2" {
  alias     = "bootstrap"
  api_url   = "https://${local.rancher_hostname}"
  bootstrap = true
  insecure  = !var.use_letsencrypt
}

resource "rancher2_bootstrap" "admin" {
  count    = var.install_ai_factory ? 1 : 0
  provider = rancher2.bootstrap

  password  = var.rancher_bootstrap_password
  telemetry = true

  # wait_for_rancher (compute.tf) already polls /healthz, which only goes
  # green once the Rancher Helm install - and therefore the admin user this
  # resource logs in as - is live. Without this, the bootstrap login could
  # race the management cluster's own first-node.sh.tpl boot script.
  depends_on = [null_resource.wait_for_rancher]
}

provider "rancher2" {
  alias     = "admin"
  api_url   = "https://${local.rancher_hostname}"
  token_key = length(rancher2_bootstrap.admin) > 0 ? rancher2_bootstrap.admin[0].token : ""
  insecure  = !var.use_letsencrypt
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