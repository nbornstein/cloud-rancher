resource "azurerm_availability_set" "avset" {
  count = var.cloud_provider == "azure" ? 1 : 0

  name                         = "avset-rke2"
  location                     = azurerm_resource_group.rg[0].location
  resource_group_name          = azurerm_resource_group.rg[0].name
  platform_fault_domain_count  = 2
  platform_update_domain_count = 5
  managed                      = true
}

# Public IPs for direct SSH management
resource "azurerm_public_ip" "rancher_node_pip" {
  count = var.cloud_provider == "azure" ? var.rancher_node_count : 0

  name                = "pip-rancher-node-${count.index + 1}"
  location            = azurerm_resource_group.rg[0].location
  resource_group_name = azurerm_resource_group.rg[0].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "rancher_nic" {
  count = var.cloud_provider == "azure" ? var.rancher_node_count : 0

  name                = "nic-rancher-node-${count.index + 1}"
  location            = azurerm_resource_group.rg[0].location
  resource_group_name = azurerm_resource_group.rg[0].name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.rancher_node_pip[count.index].id
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "rancher_nic_lb_assoc" {
  count = var.cloud_provider == "azure" ? var.rancher_node_count : 0

  network_interface_id    = azurerm_network_interface.rancher_nic[count.index].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.backend_pool[0].id
}

resource "azurerm_linux_virtual_machine" "rancher_vm" {
  count = var.cloud_provider == "azure" ? var.rancher_node_count : 0

  name                = "vm-rancher-node-${count.index + 1}"
  resource_group_name = azurerm_resource_group.rg[0].name
  location            = azurerm_resource_group.rg[0].location
  size                = var.azure_rancher_vm_size
  admin_username      = var.azure_admin_username
  availability_set_id = azurerm_availability_set.avset[0].id

  network_interface_ids = [
    azurerm_network_interface.rancher_nic[count.index].id,
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
      vm_hostname                = "vm-rancher-node-${count.index + 1}",
      sles_reg_code              = var.sles_reg_code,
      rancher_prime_reg_code     = var.rancher_prime_reg_code,
      rke2_token                 = var.rke2_token,
      lb_ip                      = local.lb_public_ip,
      rancher_hostname           = local.rancher_hostname,
      rancher_bootstrap_password = var.rancher_bootstrap_password,
      letsencrypt_email          = var.letsencrypt_email,
      ai_llm_provider            = var.ai_llm_provider,
      gemini_api_key             = var.gemini_api_key,
      gemini_model               = var.gemini_model,
      openai_api_key             = var.openai_api_key,
      openai_model               = var.openai_model,
      bedrock_model              = var.bedrock_model,
      bedrock_bearer_token       = var.bedrock_bearer_token,
      bedrock_region             = var.bedrock_region,
      bedrock_url                = var.bedrock_url,
      ollama_model               = var.ollama_model,
      ollama_url                 = var.ollama_url,
      generic_openai_model       = var.generic_openai_model,
      generic_openai_url         = var.generic_openai_url,
      generic_openai_api_key     = var.generic_openai_api_key,
      use_letsencrypt            = var.use_letsencrypt,
      tls_cert_b64               = local.tls_cert_b64,
      tls_key_b64                = local.tls_key_b64,
      ca_cert_b64                = local.ca_cert_b64,
      rke2_version               = var.rke2_version,
      rke2_ingress_controller    = local.rke2_ingress_controller,
      ingress_daemonset_name     = local.ingress_daemonset_name,
      ingress_class_name         = local.ingress_class_name,
      cert_manager_version       = var.cert_manager_version,
      rancher_version            = var.rancher_version
    }) :
    templatefile("${path.module}/templates/join-node.sh.tpl", {
      vm_hostname      = "vm-rancher-node-${count.index + 1}",
      sles_reg_code    = var.sles_reg_code,
      rke2_token       = var.rke2_token,
      rke2_version     = var.rke2_version,
      lb_ip            = local.lb_public_ip,
      first_node_ip    = azurerm_network_interface.rancher_nic[0].private_ip_address,
      rancher_hostname = local.rancher_hostname
    })
  )

}

# --- Downstream Nodes ---

# Public IPs for downstream nodes for direct SSH management
resource "azurerm_public_ip" "downstream_node_pip" {
  count = var.cloud_provider == "azure" ? var.downstream_node_count : 0

  name                = "pip-downstream-node-${count.index + 1}"
  location            = azurerm_resource_group.rg[0].location
  resource_group_name = azurerm_resource_group.rg[0].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "downstream_nic" {
  count = var.cloud_provider == "azure" ? var.downstream_node_count : 0

  name                = "nic-downstream-node-${count.index + 1}"
  location            = azurerm_resource_group.rg[0].location
  resource_group_name = azurerm_resource_group.rg[0].name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.downstream_node_pip[count.index].id
  }
}

resource "azurerm_linux_virtual_machine" "downstream_vm" {
  count = var.cloud_provider == "azure" ? var.downstream_node_count : 0

  name                = "vm-downstream-node-${count.index + 1}"
  resource_group_name = azurerm_resource_group.rg[0].name
  location            = azurerm_resource_group.rg[0].location
  size                = var.azure_downstream_vm_size
  admin_username      = var.azure_admin_username
  availability_set_id = azurerm_availability_set.avset[0].id

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

  user_data = base64encode(templatefile("${path.module}/templates/downstream-node.sh.tpl", {
    vm_hostname   = "vm-downstream-node-${count.index + 1}",
    sles_reg_code = var.sles_reg_code
  }))
}
