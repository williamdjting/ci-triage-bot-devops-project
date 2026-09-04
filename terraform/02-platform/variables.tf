variable "kubeconfig_path" {
  description = "Path to kubeconfig. kind writes the default one."
  type        = string
  default     = "~/.kube/config"
}

variable "kubeconfig_context" {
  description = "kubectl context. Must match layer 1's kubeconfig_context output."
  type        = string
  default     = "kind-ci-triage"
}

variable "ingress_nginx_chart_version" {
  description = "ingress-nginx Helm chart version (chart 4.15.1 = controller 1.15.1)."
  type        = string
  default     = "4.15.1"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (chart 10.4.1 = ArgoCD v3.5.2)."
  type        = string
  default     = "10.4.1"
}

variable "argocd_hostname" {
  description = "Hostname for the ArgoCD UI. *.localtest.me always resolves to 127.0.0.1."
  type        = string
  default     = "argocd.localtest.me"
}

variable "install_argocd" {
  description = <<-EOT
    Install ArgoCD. Kept as a flag so layer 2 is useful on its own: set false and
    you get just an ingress controller, which is all Stage 3 strictly needs.
  EOT
  type        = bool
  default     = true
}

variable "sealed_secrets_chart_version" {
  description = <<-EOT
    sealed-secrets Helm chart version (chart 2.19.3 = controller v0.39.1).
    Must match the `kubeseal` CLI version used to seal secrets -- a client
    newer than the controller can produce a blob the controller cannot open.
  EOT
  type        = string
  default     = "2.19.3"
}
