terraform {
  required_version = ">= 1.5"

  required_providers {
    kind = {
      # Community provider (self-signed, not HashiCorp). Pinned tightly because
      # it wraps the kind CLI's behaviour and moves independently of Terraform.
      source  = "tehcyx/kind"
      version = "~> 0.11"
    }
  }
}

provider "kind" {}
