resource "azurerm_public_ip" "lb_pip" {
  name                = "pip-rancher-lb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "rancher_lb" {
  name                = "lb-rancher-cluster"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "PublicFrontEnd"
    public_ip_address_id = azurerm_public_ip.lb_pip.id
  }
}

resource "azurerm_lb_backend_address_pool" "backend_pool" {
  loadbalancer_id = azurerm_lb.rancher_lb.id
  name            = "rancher-backend-pool"
}

# Health Probes
resource "azurerm_lb_probe" "probe_6443" {
  loadbalancer_id = azurerm_lb.rancher_lb.id
  name            = "rancher-api-probe"
  port            = 6443
}

resource "azurerm_lb_probe" "probe_443" {
  loadbalancer_id = azurerm_lb.rancher_lb.id
  name            = "rancher-https-probe"
  port            = 443
}

# Rules (6443 Kube-API, 80 HTTP, 443 HTTPS)
resource "azurerm_lb_rule" "rule_6443" {
  loadbalancer_id                = azurerm_lb.rancher_lb.id
  name                           = "LBRule-6443"
  protocol                       = "Tcp"
  frontend_port                  = 6443
  backend_port                   = 6443
  frontend_ip_configuration_name = "PublicFrontEnd"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend_pool.id]
  probe_id                       = azurerm_lb_probe.probe_6443.id
}

resource "azurerm_lb_rule" "rule_80" {
  loadbalancer_id                = azurerm_lb.rancher_lb.id
  name                           = "LBRule-80"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "PublicFrontEnd"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend_pool.id]
}

resource "azurerm_lb_rule" "rule_443" {
  loadbalancer_id                = azurerm_lb.rancher_lb.id
  name                           = "LBRule-443"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 443
  frontend_ip_configuration_name = "PublicFrontEnd"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend_pool.id]
  probe_id                       = azurerm_lb_probe.probe_443.id
}
