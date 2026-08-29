variable "cluster_name" {
  description = "Name of the kind cluster. Becomes kubeconfig context 'kind-<name>'."
  type        = string
  default     = "ci-triage"
}

variable "node_image" {
  description = <<-EOT
    Pinned kindest/node image. Pinning is the point of IaC: leaving it unset
    means the Kubernetes version silently follows whatever kind CLI you happen
    to have installed, so two people running `terraform apply` get different
    clusters.
  EOT
  type        = string
  default     = "kindest/node:v1.36.1"
}

variable "http_host_port" {
  description = "Host port mapped to the ingress controller's :80 inside the cluster."
  type        = number
  default     = 8080
}

variable "https_host_port" {
  description = "Host port mapped to the ingress controller's :443 inside the cluster."
  type        = number
  default     = 8443
}

variable "worker_count" {
  description = "Number of worker nodes. 2 lets you see scheduling spread pods across nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 5
    error_message = "worker_count must be between 0 and 5; each node is a container on your laptop."
  }
}
