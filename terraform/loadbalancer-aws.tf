resource "aws_eip" "lb_eip" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider = aws.compute
  domain   = "vpc"

  tags = {
    Name = "eip-rancher-lb"
  }
}

resource "aws_lb" "rancher_lb" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider           = aws.compute
  name               = "lb-rancher-cluster"
  load_balancer_type = "network"

  subnet_mapping {
    subnet_id     = aws_subnet.subnet[0].id
    allocation_id = aws_eip.lb_eip[0].id
  }

  tags = {
    Name = "lb-rancher-cluster"
  }
}

# Target groups + health checks (6443 Kube-API, 80 HTTP, 443 HTTPS), mirroring
# the Azure Standard LB's TCP probes/rules.
resource "aws_lb_target_group" "tg_6443" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider    = aws.compute
  name        = "rancher-tg-6443"
  port        = 6443
  protocol    = "TCP"
  vpc_id      = aws_vpc.vpc[0].id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "6443"
  }
}

resource "aws_lb_target_group" "tg_80" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider    = aws.compute
  name        = "rancher-tg-80"
  port        = 80
  protocol    = "TCP"
  vpc_id      = aws_vpc.vpc[0].id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "80"
  }
}

resource "aws_lb_target_group" "tg_443" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider    = aws.compute
  name        = "rancher-tg-443"
  port        = 443
  protocol    = "TCP"
  vpc_id      = aws_vpc.vpc[0].id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    port     = "443"
  }
}

resource "aws_lb_listener" "listener_6443" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider          = aws.compute
  load_balancer_arn = aws_lb.rancher_lb[0].arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_6443[0].arn
  }
}

resource "aws_lb_listener" "listener_80" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider          = aws.compute
  load_balancer_arn = aws_lb.rancher_lb[0].arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_80[0].arn
  }
}

resource "aws_lb_listener" "listener_443" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider          = aws.compute
  load_balancer_arn = aws_lb.rancher_lb[0].arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg_443[0].arn
  }
}
