data "aws_secretsmanager_secret_version" "custom_cert" {
  count = !var.use_letsencrypt && var.aws_tls_cert_secret_arn != "" ? 1 : 0

  secret_id = var.aws_tls_cert_secret_arn
}

locals {
  downstream_user_data_path = "${path.module}/templates/downstream-node.sh.tpl"
  downstream_user_data_content = fileexists(local.downstream_user_data_path) ? templatefile(local.downstream_user_data_path, {
    sles_reg_code = var.sles_reg_code
  }) : ""
  # user_data must be null or a non-empty string. An empty string will cause a provider error.
  downstream_user_data = local.downstream_user_data_content == "" ? null : base64encode(local.downstream_user_data_content)

  # Decode the custom certificate from AWS Secrets Manager if provided.
  # Gracefully handle missing keys using try().
  custom_cert_data = length(data.aws_secretsmanager_secret_version.custom_cert) > 0 ? jsondecode(data.aws_secretsmanager_secret_version.custom_cert[0].secret_string) : {}
  tls_crt_b64      = base64encode(try(local.custom_cert_data["tls.crt"], ""))
  tls_key_b64      = base64encode(try(local.custom_cert_data["tls.key"], ""))
  # The secret this project is actually populated with uses the key 'cacerts.pm' (a typo
  # that was never corrected at the source), so look for that first. Also accept the
  # correctly-spelled 'cacerts.pem' and 'ca.crt' for flexibility/forwards-compatibility.
  ca_certs_pem = try(local.custom_cert_data["cacerts.pm"], try(local.custom_cert_data["cacerts.pem"], try(local.custom_cert_data["ca.crt"], "")))
  ca_crt_b64   = base64encode(local.ca_certs_pem)
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

resource "azurerm_availability_set" "avset" {
  name                         = "avset-rke2"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  platform_fault_domain_count  = 2
  platform_update_domain_count = 5
  managed                      = true
}

# Public IPs for direct SSH management
resource "azurerm_public_ip" "node_pip" {
  count               = var.rke2_node_count
  name                = "pip-rke2-node-${count.index + 1}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "nic" {
  count               = var.rke2_node_count
  name                = "nic-rke2-node-${count.index + 1}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.node_pip[count.index].id
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "nic_lb_assoc" {
  count                   = var.rke2_node_count
  network_interface_id    = azurerm_network_interface.nic[count.index].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.backend_pool.id
}

resource "azurerm_linux_virtual_machine" "vm" {
  count               = var.rke2_node_count
  name                = "vm-rke2-node-${count.index + 1}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.azure_vm_size
  admin_username      = var.azure_admin_username
  availability_set_id = azurerm_availability_set.avset.id

  network_interface_ids = [
    azurerm_network_interface.nic[count.index].id,
  ]

  # The first node's boot script requests a Let's Encrypt certificate for
  # rancher_hostname via an HTTP-01 challenge. Terraform's dependency graph
  # has no other link between this VM and the Route53 record (it's only
  # referenced by the DNS record, not the other way around), so without this
  # the VM can boot and start the ACME challenge before the record even
  # exists. This only orders the two Terraform-side API calls; the boot
  # script still has to wait for the record to actually propagate.
  depends_on = [aws_route53_record.rancher_dns]

  admin_ssh_key {
    username   = var.azure_admin_username
    public_key = var.azure_ssh_public_key != null ? var.azure_ssh_public_key : file("~/.ssh/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 80
  }

  source_image_reference {
    publisher = "SUSE"
    offer     = "sles-15-sp7" # Marketplace default for SLES 15
    sku       = "gen2"
    version   = "latest"
  }

  user_data = base64encode(
    count.index == 0 ?
    templatefile("${path.module}/templates/first-node.sh.tpl", {
      sles_reg_code              = var.sles_reg_code,
      rancher_prime_reg_code     = var.rancher_prime_reg_code,
      rke2_token                 = var.rke2_token,
      lb_ip                      = azurerm_public_ip.lb_pip.ip_address,
      rancher_hostname           = var.rancher_hostname,
      rancher_bootstrap_password = var.rancher_bootstrap_password,
      letsencrypt_email          = var.letsencrypt_email,
      gemini_api_key             = var.gemini_api_key,
      gemini_model               = var.gemini_model,
      use_letsencrypt            = var.use_letsencrypt,
      tls_crt_b64                = local.tls_crt_b64,
      tls_key_b64                = local.tls_key_b64,
      ca_crt_b64                 = local.ca_crt_b64,
      rke2_version               = var.rke2_version,
      cert_manager_version       = var.cert_manager_version,
      rancher_version            = var.rancher_version
    }) :
    templatefile("${path.module}/templates/join-node.sh.tpl", {
      sles_reg_code    = var.sles_reg_code,
      rke2_token       = var.rke2_token,
      lb_ip            = azurerm_public_ip.lb_pip.ip_address,
      first_node_ip    = azurerm_network_interface.nic[0].private_ip_address,
      rancher_hostname = var.rancher_hostname
    })
  )

}

# --- Downstream Nodes ---

# Public IPs for downstream nodes for direct SSH management
resource "azurerm_public_ip" "downstream_node_pip" {
  count               = var.downstream_node_count
  name                = "pip-downstream-node-${count.index + 1}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "downstream_nic" {
  count               = var.downstream_node_count
  name                = "nic-downstream-node-${count.index + 1}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.downstream_node_pip[count.index].id
  }
}

resource "azurerm_linux_virtual_machine" "downstream_vm" {
  count               = var.downstream_node_count
  name                = "vm-downstream-node-${count.index + 1}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.azure_vm_size
  admin_username      = var.azure_admin_username
  availability_set_id = azurerm_availability_set.avset.id

  network_interface_ids = [
    azurerm_network_interface.downstream_nic[count.index].id,
  ]

  admin_ssh_key {
    username   = var.azure_admin_username
    public_key = var.azure_ssh_public_key != null ? var.azure_ssh_public_key : file("~/.ssh/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 80
  }

  source_image_reference {
    publisher = "SUSE"
    offer     = "sles-15-sp7"
    sku       = "gen2"
    version   = "latest"
  }

  # This user_data script is intended to prepare the node for joining a downstream cluster.
  # You will need to create a 'templates/downstream-node.sh.tpl' file.
  # A basic template would register the system with SUSE.
  user_data = local.downstream_user_data


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
    scc_system_hostname = var.rancher_hostname
    scc_username        = var.scc_username
    scc_password        = var.scc_password
    script_path         = "${path.module}/deregister-scc.sh"
  }

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.script_path

    environment = {
      SCC_USERNAME    = self.triggers.scc_username
      SCC_PASSWORD    = self.triggers.scc_password
      SYSTEM_HOSTNAME = self.triggers.scc_system_hostname
    }
  }
}

resource "null_resource" "scc_deregister_rke2_nodes" {
  # Only create this resource if SCC credentials are provided. It runs for each RKE2 node.
  count = var.scc_username != null && var.scc_password != null ? var.rke2_node_count : 0

  triggers = {
    # The hostname used for registration is assumed to be the VM's name.
    scc_system_hostname = "vm-rke2-node-${count.index + 1}"
    scc_username        = var.scc_username
    scc_password        = var.scc_password
    script_path         = "${path.module}/deregister-scc.sh"
    # Explicit dependency on the VM resource.
    vm_id = azurerm_linux_virtual_machine.vm[count.index].id
  }

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.script_path

    environment = {
      SCC_USERNAME    = self.triggers.scc_username
      SCC_PASSWORD    = self.triggers.scc_password
      SYSTEM_HOSTNAME = self.triggers.scc_system_hostname
    }
  }
}

resource "null_resource" "scc_deregister_downstream_nodes" {
  # Only create this resource if SCC credentials are provided. It runs for each downstream node.
  count = var.scc_username != null && var.scc_password != null ? var.downstream_node_count : 0

  triggers = {
    # The hostname used for registration is assumed to be the VM's name.
    scc_system_hostname = "vm-downstream-node-${count.index + 1}"
    scc_username        = var.scc_username
    scc_password        = var.scc_password
    script_path         = "${path.module}/deregister-scc.sh"
    # Explicit dependency on the VM resource.
    vm_id = azurerm_linux_virtual_machine.downstream_vm[count.index].id
  }

  provisioner "local-exec" {
    when    = destroy
    command = self.triggers.script_path

    environment = {
      SCC_USERNAME    = self.triggers.scc_username
      SCC_PASSWORD    = self.triggers.scc_password
      SYSTEM_HOSTNAME = self.triggers.scc_system_hostname
    }
  }
}

# --- Wait for Rancher Server ---

# This resource uses a local-exec provisioner to poll the Rancher health
# endpoint. It blocks the Terraform apply process until Rancher is fully
# installed and ready, or until it times out. This provides feedback to the
# user and ensures that the deployment is complete when Terraform finishes.
resource "null_resource" "wait_for_rancher" {
  # Only run this waiter if at least one RKE2 node is being created.
  count = var.rke2_node_count > 0 ? 1 : 0

  # Using triggers ensures that this resource is re-evaluated if these values change.
  # It also makes the dependency on the load balancer's IP explicit.
  triggers = {
    # This resource logically depends on the first VM where Rancher is installed.
    vm_id            = azurerm_linux_virtual_machine.vm[0].id
    rancher_hostname = var.rancher_hostname
    # The lb_pip resource is assumed to be in a separate loadbalancer.tf file
    lb_public_ip    = azurerm_public_ip.lb_pip.ip_address
    use_letsencrypt = var.use_letsencrypt
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    # This script polls the Rancher health endpoint using curl.
    # For Let's Encrypt, it performs a strict check, failing if the certificate is not valid.
    # This prevents Terraform from reporting success when the certificate is bad.
    command = <<-EOT
      echo "Waiting for Rancher server to become available with a valid certificate at https://${self.triggers.rancher_hostname}"
      echo "This can take up to 20 minutes. Polling..."
      end_time=$((SECONDS+1200)) # 20 minute timeout

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

      echo "Error: Timed out after 20 minutes waiting for Rancher to become healthy on HTTPS." >&2
      echo "If using Let's Encrypt, this likely means the certificate could not be obtained." >&2
      echo "Please check the cloud-init logs on 'vm-rke2-node-1' for errors: 'sudo journalctl -u cloud-final'" >&2
      exit 1
    EOT
  }
}
