# ---------------------------------------------------------------------------
# The state backend. This runs ONCE, before anything else, and it is the piece
# every solo portfolio project skips.
#
# Local state works fine until a second engineer exists. Then:
#   - two people apply at the same time and the last write wins, silently
#   - the state file holds every credential the config touched, in plain text,
#     sitting in a git repo or a laptop's home directory
#   - somebody's machine dies and the only record of what is deployed dies too
#
# So state goes in S3, versioned and encrypted, with a DynamoDB table holding
# the lock. That combination is what makes Terraform safe for a team, and it is
# the difference between a lab and something you would run at work.
#
# Chicken and egg: you cannot store the backend's own state in the backend it
# is creating. This root uses local state on purpose and creates almost
# nothing, which is the standard way to bootstrap.
#
# COST: S3 holds a few KB. DynamoDB is on-demand billing, and a lock is a
# handful of writes per apply. Effectively zero, and it stays up between
# sessions so the lock actually means something.
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

locals {
  # Bucket names are globally unique across all of AWS, so the account id is
  # appended rather than hoping "lab13-tfstate" is free.
  bucket = "lab13-tfstate-${data.aws_caller_identity.me.account_id}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket

  # NOT force_destroy. State is the record of what exists in the account; if
  # this bucket is emptied by accident, Terraform loses track of live resources
  # and you are reconciling by hand. Deleting it should require intent.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning is the actual recovery mechanism. A corrupted or truncated state
# push is recoverable by rolling back to the previous object version, and
# without this that is simply gone.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# State contains secrets. Not "might" contain: lab 01 measured it, a data
# source value lands in state in plain text even when nothing references it.
# So the bucket is encrypted, using the AWS managed key because a customer
# managed key costs a dollar a month and buys nothing here.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deny any request that is not using TLS. Without this a misconfigured client
# can push state over plain HTTP, and state is the one object in the account
# guaranteed to contain credentials.
resource "aws_s3_bucket_policy" "state_tls_only" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.state.arn,
        "${aws_s3_bucket.state.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# The lock. Terraform writes an item here for the duration of an apply, so a
# second apply blocks instead of racing. PAY_PER_REQUEST because a lock table
# sees a few writes a day and provisioned capacity would be billed hourly for
# nothing.
resource "aws_dynamodb_table" "locks" {
  name         = "lab13-tfstate-locks"
  billing_mode = "PAY_PER_REQUEST"

  # LockID is not a name I chose. Terraform requires exactly this attribute as
  # the hash key, and a different one fails at init with an unhelpful error.
  hash_key = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "backend_config" {
  value = <<-EOT

    Bootstrap complete. Put this in terraform/backend.tf:

      terraform {
        backend "s3" {
          bucket         = "${aws_s3_bucket.state.id}"
          key            = "lab13/terraform.tfstate"
          region         = "${data.aws_region.current.name}"
          dynamodb_table = "${aws_dynamodb_table.locks.name}"
          encrypt        = true
        }
      }
  EOT
}
