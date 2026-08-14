# Remote state, created by terraform/bootstrap.
#
# This is the line that separates a portfolio project from something a team
# could actually run. Local state means one person, one laptop, and a file full
# of plaintext credentials sitting in a home directory. Remote state means the
# record lives somewhere durable, versioned and encrypted, and the DynamoDB
# lock stops two applies racing each other.
#
# Values are literal on purpose. A backend block cannot use variables or
# interpolation, which surprises people the first time they try.
terraform {
  backend "s3" {
    bucket         = "lab13-tfstate-299952486573"
    key            = "lab13/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "lab13-tfstate-locks"
    encrypt        = true
  }
}
