data "aws_availability_zones" "available" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider = aws.compute
  state    = "available"
}

resource "aws_vpc" "vpc" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider             = aws.compute
  cidr_block           = var.aws_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "vpc-rke2-prod"
  }
}

resource "aws_internet_gateway" "igw" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider = aws.compute
  vpc_id   = aws_vpc.vpc[0].id

  tags = {
    Name = "igw-rke2"
  }
}

# A single public subnet in one AZ, matching the single-subnet model used on the
# Azure side (no multi-AZ spread yet - see avset's comment in compute-azure.tf
# for why Azure's HA story doesn't carry over 1:1 either).
resource "aws_subnet" "subnet" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider                = aws.compute
  vpc_id                  = aws_vpc.vpc[0].id
  cidr_block              = cidrsubnet(var.aws_vpc_cidr, 8, 1)
  availability_zone       = data.aws_availability_zones.available[0].names[0]
  map_public_ip_on_launch = false # nodes get a stable IP from an explicit aws_eip instead

  tags = {
    Name = "snet-rke2-nodes"
  }
}

resource "aws_route_table" "rt" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider = aws.compute
  vpc_id   = aws_vpc.vpc[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw[0].id
  }

  tags = {
    Name = "rt-rke2-public"
  }
}

resource "aws_route_table_association" "rta" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider       = aws.compute
  subnet_id      = aws_subnet.subnet[0].id
  route_table_id = aws_route_table.rt[0].id
}

resource "aws_security_group" "nsg" {
  count = var.cloud_provider == "aws" ? 1 : 0

  provider    = aws.compute
  name        = "rke2-nodes-sg"
  description = "RKE2/Rancher node traffic (SSH, Kube-API, HTTP, HTTPS)"
  vpc_id      = aws_vpc.vpc[0].id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Restrict in production to your IP
  }

  ingress {
    description = "Kube-API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "rke2-nodes-sg"
  }
}
