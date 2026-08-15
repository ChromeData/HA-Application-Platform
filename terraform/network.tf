# ---------------------------------------------------------------------------
# The network the platform sits on.
#
# This file used to be 130 lines of VPC, subnets, route tables and
# associations. It is now a module call, because lab 12 had the same 130 lines
# with different names. Two copies of a pattern is where copy-paste stops being
# cheaper than an interface, so the pattern was extracted into lab 14,
# terraform-aws-secure-vpc, and this is its first consumer.
#
# The whole availability story still starts here. An application is only as
# available as the failure domains it spans, and in AWS that domain is the
# availability zone: a separate physical facility with its own power and
# cooling. Two AZs means a datacenter can go dark and the app stays up.
#
# COST: everything below is free. VPC, subnets, route tables, security groups,
# internet gateways and gateway endpoints cost nothing. NAT is the expensive
# part at roughly $32 a month per AZ, and the module defaults it off, which is
# why the private subnets have no outbound internet path. Nothing here needs one.
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

# --- the network ---------------------------------------------------------------
#
# Pinned to a tag, not a branch and not a relative path.
#
# The relative path is tempting because both labs sit in one working copy, and
# it is wrong for two reasons. It does not exist once this lab is its own
# repository, and more importantly a change to the module would reach every
# consumer on the next apply with no version bump and nothing to review. That
# is the entire problem versioning exists to solve, so paying the small cost of
# a tag is the point rather than an inconvenience.
#
# ?ref=main would have the same defect with extra steps.
#
# What this call did NOT have to say is the interesting part. No NAT, no public
# IP on private subnets, no default security group cleanup, no per-AZ route
# tables. Those are the module's defaults, so the secure posture is what you get
# for writing nothing, and turning it off is the thing that takes an argument.
module "vpc" {
  source = "git::https://github.com/ChromeData/terraform-aws-secure-vpc.git?ref=v0.1.0"

  name       = "lab13"
  cidr_block = "10.30.0.0/16"
  az_count   = 2

  # Two is the honest minimum that survives losing a datacenter. Three would be
  # more available and would also triple the NAT and endpoint cost in a real
  # build.

  # Left at the default of false. The app tier serves a page using only what
  # ships on the AMI precisely so this can stay off; see the note in compute.tf
  # about the dnf install that hung forever.
  # enable_nat_gateway = false

  tags = { Lab = "13-ha-application-platform" }
}

# One behaviour changed in the move, and it is an improvement rather than a
# port. This lab originally used a single private route table shared by both
# AZs. The module gives each AZ its own. With no NAT that is cosmetic, but the
# moment egress is added a shared table routes every AZ through one gateway,
# which turns a cost optimisation into a single point of failure in the tier
# that was supposed to be the redundant one.
#
# The refactor also added a free S3 gateway endpoint, which is the module's
# default and the reason NAT stays unnecessary for anything that just needs S3.

# --- keeping the refactor from destroying the network -------------------------
#
# Moving a resource into a module changes its address in state, and Terraform
# tracks resources by address. So to Terraform this refactor does not look like
# a refactor. It looks like "delete the entire network and build a new one",
# which on a live environment means every instance replaced and the ALB given a
# new DNS name, for a change that was supposed to be cosmetic.
#
# I measured it rather than assuming it. Same refactor, offline, using the null
# provider so it cost nothing:
#
#   without moved blocks   Plan: 3 to add, 0 to change, 3 to destroy
#   with moved blocks      Plan: 0 to add, 0 to change, 0 to destroy
#
# A moved block tells Terraform the old address and the new one are the same
# object, so it updates the state pointer instead of replacing anything. Full
# transcript in findings/state-move-proof.txt.
#
# HONEST SCOPE: the mechanic above is proven. These specific blocks are not,
# because this lab's infrastructure was destroyed after the chaos test and there
# is no live state left to move. They are validated for syntax and address
# correctness, not exercised. Anyone applying this against a live lab 13 should
# read the plan before approving it, which is the rule regardless.

moved {
  from = aws_vpc.main
  to   = module.vpc.aws_vpc.this
}

moved {
  from = aws_internet_gateway.main
  to   = module.vpc.aws_internet_gateway.this
}

moved {
  from = aws_subnet.public
  to   = module.vpc.aws_subnet.public
}

moved {
  from = aws_subnet.private
  to   = module.vpc.aws_subnet.private
}

moved {
  from = aws_route_table.public
  to   = module.vpc.aws_route_table.public
}

# Not a clean one-to-one. The old config had a single private route table shared
# by both AZs; the module makes one per AZ. So the existing table becomes index
# 0 and index 1 is genuinely new, which means this refactor is not purely
# cosmetic and the plan will say so.
#
# The knock-on: the private association for AZ 1 now points at a different route
# table, and route_table_id is not updatable in place, so that one association
# gets replaced. Replacing a route table association is a few seconds of
# nothing on a tier with no routes in it. Worth knowing before approving,
# not worth avoiding.
moved {
  from = aws_route_table.private
  to   = module.vpc.aws_route_table.private[0]
}

moved {
  from = aws_route_table_association.public
  to   = module.vpc.aws_route_table_association.public
}

moved {
  from = aws_route_table_association.private
  to   = module.vpc.aws_route_table_association.private
}

# The module gates this on a variable, so it is a counted resource now and the
# index is part of the address.
moved {
  from = aws_default_security_group.locked
  to   = module.vpc.aws_default_security_group.locked[0]
}

# --- what the rest of the lab reads -------------------------------------------
#
# compute.tf refers to these locals rather than module.vpc directly. That keeps
# the module boundary in one file, so swapping the source or changing an output
# name is a change here and nowhere else.
locals {
  vpc_id      = module.vpc.vpc_id
  public_ids  = module.vpc.public_subnet_ids
  private_ids = module.vpc.private_subnet_ids
  azs         = module.vpc.availability_zones
}

# The module exports this so a consumer can assert on it. Worth doing: a future
# version that quietly gained an egress path would change the security posture
# of this lab with no visible diff in this file, and a precondition turns that
# silent change into a failed plan.
check "private_tier_stays_isolated" {
  assert {
    condition     = module.vpc.has_internet_egress == false
    error_message = "The private tier gained an internet path. Nothing in this lab needs one, so this is either a mistake or a decision that belongs in a commit message."
  }
}

output "vpc_id" { value = local.vpc_id }
output "public_subnet_ids" { value = local.public_ids }
output "private_subnet_ids" { value = local.private_ids }
output "azs" { value = local.azs }
