terraform {
  required_version = ">= 1.5"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
  }
}

# Both providers point at a STATIC kubeconfig path and context, deliberately.
#
# The tempting alternative -- reading the endpoint and certs straight off the
# kind_cluster resource -- forces Terraform to configure a provider from values
# that do not exist until apply time, which fails on a clean run. Splitting the
# cluster into layer 1 means this path is a plain string that is always known.
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kubeconfig_context
}

provider "helm" {
  kubernetes = {
    config_path    = var.kubeconfig_path
    config_context = var.kubeconfig_context
  }
}
