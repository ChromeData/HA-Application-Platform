# ---------------------------------------------------------------------------
# The network the platform sits on.
#
# The whole availability story starts here. An application is only as available
# as the failure domains it spans, and in AWS the failure domain is the
# availability zone: a separate physical facility with its own power and
# cooling. Two AZs means a datacenter can go dark and the app stays up.
#
# One subnet in one AZ is the single most common thing that makes a "highly
# available" design not highly available.
#
# COST: VPC, subnets, route tables, security groups and internet gateways are
# free. A NAT gateway is roughly $32 a month and is NOT used here, which is why
# the private subnets have no outbound internet path. Nothing in this design
# needs one.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
  }
}

provider "aws" {
  default_tags {
    tags = { Purpose = "pam-cloud-lab", Lab = "13-ha-application-platform" }
  }
}

data "aws_caller_identity" "me" {}
data "aws_region" "current" {}

# Queried rather than hardcoded. "us-east-1a" is not the same physical building
# for two different AWS accounts; AWS shuffles the mapping per account. Asking
# the API is the only way to get zones this account can actually use.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Exactly two. Three would be more available and would also triple the NAT
  # and endpoint cost in a real build; two is the honest minimum that survives
  # losing a datacenter.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  public_cidrs  = ["10.30.1.0/24", "10.30.2.0/24"]
  private_cidrs = ["10.30.11.0/24", "10.30.12.0/24"]
}

resource "aws_vpc" "main" {
  cidr_block           = "10.30.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true # RDS endpoints resolve by name, so this is required
  tags                 = { Name = "lab13-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lab13-igw" }
}

# --- public subnets, one per AZ ----------------------------------------------
#
# The load balancer lives here. It needs a public path in, and it needs a
# subnet in every AZ it serves, otherwise it cannot route to targets in the AZ
# it is missing.

resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "lab13-public-${local.azs[count.index]}", Tier = "public" }
}

# --- private subnets, one per AZ ---------------------------------------------
#
# Application instances and the database live here. No public IPs, no route to
# the internet gateway. The only thing that can reach them is the load
# balancer, and the only thing the database accepts is the app tier.

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = false
  tags                    = { Name = "lab13-private-${local.azs[count.index]}", Tier = "private" }
}

# --- routing -----------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "lab13-public-rt" }
}

# No default route. Same design as lab 12: the private tier has no path off the
# network at all, so a compromised instance cannot call out even if it wanted
# to. This is also why there is no NAT gateway to pay for.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lab13-private-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Explicit, so the subnet can never silently fall back to the VPC main route
# table. That fallback is how a "private" subnet quietly becomes public.
resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- the default security group, locked ---------------------------------------
#
# AWS creates this in every VPC, it cannot be deleted, and it ships allowing
# all outbound traffic. Anything launched without an explicit group lands in
# it. Lab 12's verifier caught exactly this, so it gets stripped here from the
# start rather than discovered later.
resource "aws_default_security_group" "locked" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lab13-default-locked" }
}

output "vpc_id" { value = aws_vpc.main.id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "azs" { value = local.azs }
