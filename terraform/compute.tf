# Fetches the custom TLS certificate from AWS Secrets Manager when not using Let's Encrypt.
data "aws_secretsmanager_secret_version" "custom_cert" {
  count = !var.use_letsencrypt && var.aws_tls_cert_secret_arn != "" ? 1 : 0

  secret_id = var.aws_tls_cert_secret_arn
}

locals {
  # Starting with RKE2 v1.36, Traefik replaces ingress-nginx as the default packaged
  # ingress controller (see var.rke2_version). Derive which one this deployment uses
  # from the version string itself, so the two stay in sync automatically instead of
  # relying on a separate toggle that could drift from the pinned version.
  # An empty rke2_version means "install the absolute latest release", which is >= 1.36.
  rke2_version_parts = var.rke2_version == "" ? ["1", "36"] : regex("^v(\\d+)\\.(\\d+)", var.rke2_version)
  use_traefik = (
    tonumber(local.rke2_version_parts[0]) > 1 ||
    (tonumber(local.rke2_version_parts[0]) == 1 && tonumber(local.rke2_version_parts[1]) >= 36)
  )
  rke2_ingress_controller = local.use_traefik ? "traefik" : "ingress-nginx"
  ingress_daemonset_name  = local.use_traefik ? "rke2-traefik" : "rke2-ingress-nginx-controller"
  ingress_class_name      = local.use_traefik ? "traefik" : "nginx"

  # Decode the custom certificate from AWS Secrets Manager if provided.
  # Gracefully handle missing keys using try().
  custom_cert_data = length(data.aws_secretsmanager_secret_version.custom_cert) > 0 ? jsondecode(data.aws_secretsmanager_secret_version.custom_cert[0].secret_string) : {}
  tls_cert_b64     = base64encode(try(local.custom_cert_data["tls.crt"], ""))
  tls_key_b64      = base64encode(try(local.custom_cert_data["tls.key"], ""))
  # The secret this project is actually populated with uses the key 'cacerts.pm' (a typo
  # that was never corrected at the source), so look for that first. Also accept the
  # correctly-spelled 'cacerts.pem' and 'ca.crt' for flexibility/forwards-compatibility.
  ca_cert_pem = try(local.custom_cert_data["cacerts.pm"], try(local.custom_cert_data["cacerts.pem"], try(local.custom_cert_data["ca.crt"], "")))
  ca_cert_b64 = base64encode(local.ca_cert_pem)

  # --- Cloud-agnostic views over whichever cloud_provider's resources are active ---
  # Everything outside compute-azure.tf/compute-aws.tf (DNS, outputs, the waiters/
  # de-registration below) reads these instead of reaching into cloud-specific
  # resources directly, so it doesn't need to know or care which cloud is in use.
  lb_public_ip = (
    var.cloud_provider == "azure" ? azurerm_public_ip.lb_pip[0].ip_address :
    var.cloud_provider == "aws" ? aws_eip.lb_eip[0].public_ip :
    google_compute_address.lb_ip[0].address
  )

  rancher_vm_ids = (
    var.cloud_provider == "azure" ? azurerm_linux_virtual_machine.rancher_vm[*].id :
    var.cloud_provider == "aws" ? aws_instance.rancher_vm[*].id :
    google_compute_instance.rancher_vm[*].id
  )
  downstream_vm_ids = (
    var.cloud_provider == "azure" ? azurerm_linux_virtual_machine.downstream_vm[*].id :
    var.cloud_provider == "aws" ? aws_instance.downstream_vm[*].id :
    google_compute_instance.downstream_vm[*].id
  )
  admin_username = (
    var.cloud_provider == "azure" ? var.azure_admin_username :
    var.cloud_provider == "aws" ? var.aws_admin_username :
    var.gcp_admin_username
  )

  rancher_node_public_ips = (
    var.cloud_provider == "azure" ? azurerm_public_ip.rancher_node_pip[*].ip_address :
    var.cloud_provider == "aws" ? aws_eip.rancher_node_eip[*].public_ip :
    google_compute_address.rancher_node_external_ip[*].address
  )
  downstream_node_public_ips = (
    var.cloud_provider == "azure" ? azurerm_public_ip.downstream_node_pip[*].ip_address :
    var.cloud_provider == "aws" ? aws_eip.downstream_node_eip[*].public_ip :
    google_compute_address.downstream_node_external_ip[*].address
  )
}

# Without this, an empty/misconfigured aws_tls_cert_secret_arn when use_letsencrypt = false
# doesn't fail here - it silently flows through as base64encode("") and only surfaces much
# later as an obscure TLS handshake / ingress-controller failure. A variable "validation"
# block can't reference other variables, so this uses a resource precondition instead,
# which runs at plan time regardless of the custom_cert data source's own count.
resource "null_resource" "validate_custom_cert_config" {
  lifecycle {
    precondition {
      condition = (
        var.use_letsencrypt ||
        (
          var.aws_tls_cert_secret_arn != "" &&
          try(local.custom_cert_data["tls.crt"], "") != "" &&
          try(local.custom_cert_data["tls.key"], "") != ""
        )
      )
      error_message = "When use_letsencrypt = false, aws_tls_cert_secret_arn must point to a Secrets Manager secret containing non-empty 'tls.crt' and 'tls.key' keys."
    }
  }
}

# Each LLM provider needs its own credential/endpoint variable(s); without this,
# selecting a provider whose variable was left unset silently installs the AI
# Assistant with an empty API key/URL instead of failing at plan time.
resource "null_resource" "validate_ai_llm_provider_config" {
  lifecycle {
    precondition {
      condition = (
        var.ai_llm_provider == "" ||
        (var.ai_llm_provider == "gemini" && var.gemini_api_key != null && var.gemini_api_key != "") ||
        (var.ai_llm_provider == "openai" && var.openai_api_key != null && var.openai_api_key != "") ||
        (var.ai_llm_provider == "bedrock" && var.bedrock_bearer_token != null && var.bedrock_bearer_token != "") ||
        (var.ai_llm_provider == "ollama" && var.ollama_url != null && var.ollama_url != "") ||
        (var.ai_llm_provider == "generic-openai" && var.generic_openai_url != null && var.generic_openai_url != "" &&
        var.generic_openai_api_key != null && var.generic_openai_api_key != "")
      )
      error_message = "The variable(s) required for ai_llm_provider = \"${var.ai_llm_provider}\" are not set. See variables.tf for which variable(s) each provider requires."
    }
  }
}

# Without this, setting app_collection_username but leaving the password unset
# would silently skip adding the repo (or add it with broken credentials)
# instead of failing at plan time.
resource "null_resource" "validate_app_collection_config" {
  lifecycle {
    precondition {
      condition = (
        var.app_collection_username == "" ||
        (var.app_collection_password != null && var.app_collection_password != "")
      )
      error_message = "app_collection_password must be set when app_collection_username is set."
    }
  }
}

# --- Destroy-time De-registration ---

# These null_resources act as a hook to run a de-registration script when
# the associated VMs are destroyed. This pattern is necessary because a
# destroy-time provisioner cannot directly reference variables like var.scc_username.
#
# By storing the necessary data in the 'triggers' map, the values are snapshotted
# in the Terraform state and become accessible to the provisioner via 'self.triggers'
# during the destroy phase.

resource "null_resource" "scc_deregister_rancher_manager" {
  # Only create this resource if SCC credentials are provided. It runs only once
  # to de-register the single Rancher Manager instance.
  count = var.scc_username != null && var.scc_password != null ? 1 : 0

  triggers = {
    # We are targeting the Rancher Manager registration, which is identified
    # in SCC by the FQDN of the Rancher instance.
    scc_registration_name = local.rancher_hostname
    scc_username          = var.scc_username
    scc_password          = var.scc_password
    script_path           = "${path.module}/deregister-scc.sh"
  }

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.script_path

    environment = {
      SCC_USERNAME      = self.triggers.scc_username
      SCC_PASSWORD      = self.triggers.scc_password
      REGISTRATION_NAME = self.triggers.scc_registration_name
    }
  }
}

resource "null_resource" "scc_deregister_rancher_nodes" {
  # Only create this resource if SCC credentials are provided. It runs for each Rancher node.
  count = var.scc_username != null && var.scc_password != null ? var.rancher_node_count : 0

  triggers = {
    # The hostname used for registration is the VM's OS hostname, which the boot
    # script sets to match this naming convention via hostnamectl on every cloud.
    scc_registration_name = "vm-rancher-node-${count.index + 1}"
    scc_username          = var.scc_username
    scc_password          = var.scc_password
    script_path           = "${path.module}/deregister-scc.sh"
    # Explicit dependency on the VM resource.
    vm_id = local.rancher_vm_ids[count.index]
  }

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.script_path

    environment = {
      SCC_USERNAME      = self.triggers.scc_username
      SCC_PASSWORD      = self.triggers.scc_password
      REGISTRATION_NAME = self.triggers.scc_registration_name
    }
  }
}

resource "null_resource" "scc_deregister_downstream_nodes" {
  # Only create this resource if SCC credentials are provided. It runs for each downstream node.
  count = var.scc_username != null && var.scc_password != null ? var.downstream_node_count : 0

  triggers = {
    # The hostname used for registration is the VM's OS hostname, which the boot
    # script sets to match this naming convention via hostnamectl on every cloud.
    scc_registration_name = "vm-downstream-node-${count.index + 1}"
    scc_username          = var.scc_username
    scc_password          = var.scc_password
    script_path           = "${path.module}/deregister-scc.sh"
    # Explicit dependency on the VM resource.
    vm_id = local.downstream_vm_ids[count.index]
  }

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.script_path

    environment = {
      SCC_USERNAME      = self.triggers.scc_username
      SCC_PASSWORD      = self.triggers.scc_password
      REGISTRATION_NAME = self.triggers.scc_registration_name
    }
  }
}

# --- Wait for Rancher Server ---

# This resource uses a local-exec provisioner to poll the Rancher health
# endpoint. It blocks the Terraform apply process until Rancher is fully
# installed and ready, or until it times out. This provides feedback to the
# user and ensures that the deployment is complete when Terraform finishes.
resource "null_resource" "wait_for_rancher" {
  # Only run this waiter if at least one Rancher node is being created.
  count = var.rancher_node_count > 0 ? 1 : 0

  # Using triggers ensures that this resource is re-evaluated if these values change.
  # It also makes the dependency on the load balancer's IP explicit.
  triggers = {
    # This resource logically depends on the first VM where Rancher is installed.
    vm_id            = local.rancher_vm_ids[0]
    rancher_hostname = local.rancher_hostname
    lb_public_ip     = local.lb_public_ip
    use_letsencrypt  = var.use_letsencrypt
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    # This script polls the Rancher health endpoint using curl.
    # For Let's Encrypt, it performs a strict check, failing if the certificate is not valid.
    # This prevents Terraform from reporting success when the certificate is bad.
    command = <<-EOT
      echo "Waiting for Rancher server to become available with a valid certificate at https://${self.triggers.rancher_hostname}"
      echo "This can take up to 40 minutes: it starts polling as soon as the instance exists, well before"
      echo "cloud-init finishes RKE2 install, cert-manager, and the Rancher Helm install/rollout. Polling..."
      end_time=$((SECONDS+2400)) # 40 minute timeout

      while [ $SECONDS -lt $end_time ]; do
        # For Let's Encrypt, we perform a strict check. Curl will exit with a non-zero code
        # if the certificate is not trusted by the system's CA store.
        if [ "${self.triggers.use_letsencrypt}" = "true" ]; then
          # The '--fail' flag ensures curl returns an error for HTTP codes like 404 or 503.
          # The lack of '--insecure' ensures curl validates the certificate.
          # We capture stderr to diagnose the specific error.
          curl_error=$(curl --fail --silent --show-error --connect-timeout 10 --resolve ${self.triggers.rancher_hostname}:443:${self.triggers.lb_public_ip} https://${self.triggers.rancher_hostname}/healthz 2>&1 >/dev/null)
          if [ $? -eq 0 ]; then
            echo "Successfully connected to Rancher with a valid Let's Encrypt certificate."
            echo "Rancher deployment is ready."
            exit 0
          else
            if [[ "$curl_error" == *"self-signed certificate"* ]]; then
              echo "Rancher is up but is still using a self-signed certificate. Waiting for Let's Encrypt..."
            else
              echo "Rancher not ready yet. Polling check failed: $curl_error. Retrying in 20 seconds..."
            fi
          fi
        else
          # For custom certs, we can only check if the application is responsive,
          # as the CA might not be in the system's trust store.
          https_code=$(curl --resolve ${self.triggers.rancher_hostname}:443:${self.triggers.lb_public_ip} --insecure --silent --output /dev/null --write-out "%%{http_code}" https://${self.triggers.rancher_hostname}/healthz)
          if [ "$https_code" = "200" ]; then
            echo "Rancher application is ready with a custom certificate (HTTPS /healthz returned 200)."
            exit 0
          fi
          echo "Rancher not ready yet (HTTPS /healthz code: $https_code). Retrying in 20 seconds..."
        fi
        sleep 20
      done

      echo "Error: Timed out after 40 minutes waiting for Rancher to become healthy on HTTPS." >&2
      echo "If using Let's Encrypt, this likely means the certificate could not be obtained." >&2
      echo "Please check the cloud-init logs on 'vm-rancher-node-1' for errors: 'sudo journalctl -u cloud-final'" >&2
      exit 1
    EOT
  }
}
