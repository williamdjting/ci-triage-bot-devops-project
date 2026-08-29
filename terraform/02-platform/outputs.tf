output "app_url" {
  description = "The CI Triage Bot, once its Ingress has a controller."
  value       = "http://ci-triage.localtest.me:8080"
}

output "argocd_url" {
  description = "ArgoCD UI."
  value       = var.install_argocd ? "http://${var.argocd_hostname}:8080" : "(argocd not installed)"
}

output "argocd_admin_password_command" {
  description = <<-EOT
    How to read the generated admin password. Deliberately a command rather than
    a Terraform output: reading the Secret into Terraform would write the
    password into terraform.tfstate in plaintext, forever.
  EOT
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}
