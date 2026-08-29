output "cluster_name" {
  description = "kind cluster name."
  value       = kind_cluster.this.name
}

output "kubeconfig_context" {
  description = "kubectl context created by kind. Layer 2 targets this."
  value       = "kind-${kind_cluster.this.name}"
}

output "kubeconfig_path" {
  description = "Path to the kubeconfig kind wrote."
  value       = kind_cluster.this.kubeconfig_path
}

output "endpoint" {
  description = "Kubernetes API server endpoint."
  value       = kind_cluster.this.endpoint
}

output "app_url" {
  description = "Where the app is reachable once layer 2 installs ingress-nginx."
  value       = "http://ci-triage.localtest.me:${var.http_host_port}"
}
