resource "azurerm_public_ip" "lb_pip" {
  count = var.cloud_provider == "azure" ? 1 : 0

  name                = "pip-rancher-lb"
  location            = azurerm_resource_group.rg[0].location
  resource_group_name = azurerm_resource_group.rg[0].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "rancher_lb" {
  count = var.cloud_provider == "azure" ? 1 : 0

  name                = "lb-rancher-cluster"
  location            = azurerm_resource_group.rg[0].location
  resource_group_name = azurerm_resource_group.rg[0].name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "PublicFrontEnd"
    public_ip_address_id = azurerm_public_ip.lb_pip[0].id
  }
}

resource "azurerm_lb_backend_address_pool" "backend_pool" {
  count = var.cloud_provider == "azure" ? 1 : 0

  loadbalancer_id = azurerm_lb.rancher_lb[0].id
  name            = "rancher-backend-pool"
}

# Health Probes
resource "azurerm_lb_probe" "probe_6443" {
  count = var.cloud_provider == "azure" ? 1 : 0

  loadbalancer_id = azurerm_lb.rancher_lb[0].id
  name            = "rancher-api-probe"
  port            = 6443
}

resource "azurerm_lb_probe" "probe_443" {
  count = var.cloud_provider == "azure" ? 1 : 0

  loadbalancer_id = azurerm_lb.rancher_lb[0].id
  name            = "rancher-https-probe"
  port            = 443
}

# Rules (6443 Kube-API, 80 HTTP, 443 HTTPS)
resource "azurerm_lb_rule" "rule_6443" {
  count = var.cloud_provider == "azure" ? 1 : 0

  loadbalancer_id                = azurerm_lb.rancher_lb[0].id
  name                           = "LBRule-6443"
  protocol                       = "Tcp"
  frontend_port                  = 6443
  backend_port                   = 6443
  frontend_ip_configuration_name = "PublicFrontEnd"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend_pool[0].id]
  probe_id                       = azurerm_lb_probe.probe_6443[0].id
}

resource "azurerm_lb_rule" "rule_80" {
  count = var.cloud_provider == "azure" ? 1 : 0

  loadbalancer_id                = azurerm_lb.rancher_lb[0].id
  name                           = "LBRule-80"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "PublicFrontEnd"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend_pool[0].id]
}

resource "azurerm_lb_rule" "rule_443" {
  count = var.cloud_provider == "azure" ? 1 : 0

  loadbalancer_id                = azurerm_lb.rancher_lb[0].id
  name                           = "LBRule-443"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "PublicFrontEnd"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend_pool[0].id]
  probe_id                       = azurerm_lb_probe.probe_443[0].id
}
