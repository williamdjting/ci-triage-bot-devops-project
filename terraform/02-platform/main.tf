# ---------------------------------------------------------------------------
# Layer 2: the platform. Cluster-wide services that apps depend on but do not
# own. This is the boundary Terraform should stop at -- it installs ArgoCD, it
# does not deploy the app. The app is ArgoCD's job from Stage 4 onward.
# ---------------------------------------------------------------------------

# --- ingress-nginx ---------------------------------------------------------
# Turns the Ingress object in k8s/ingress.yaml from an inert request into
# actual routing. An Ingress without a controller does nothing at all.
resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.ingress_nginx_chart_version

  namespace        = "ingress-nginx"
  create_namespace = true

  # The admission webhook's cert job makes first install slow on kind.
  timeout = 600
  wait    = true

  values = [yamlencode({
    controller = {
      # Bind the controller directly to the node's :80/:443, which kind maps to
      # localhost:8080/8443 via extraPortMappings in layer 1. This is the piece
      # that makes ingress reachable from macOS.
      hostPort = {
        enabled = true
      }

      # kind has no cloud load balancer, so a LoadBalancer Service would sit in
      # <pending> forever. hostPort above is doing the real work.
      service = {
        type = "NodePort"
      }

      # Pin to the node carrying the port mappings -- the control-plane node
      # labelled ingress-ready=true in layer 1.
      nodeSelector = {
        "ingress-ready" = "true"
      }

      # ...which is tainted NoSchedule by default, so it needs a toleration.
      tolerations = [{
        key      = "node-role.kubernetes.io/control-plane"
        operator = "Equal"
        effect   = "NoSchedule"
      }]

      # No cloud LB to publish, so don't wait on one for Ingress status.
      publishService = {
        enabled = false
      }

      # Adopt Ingresses that omit ingressClassName. Ours sets it explicitly,
      # but this avoids a confusing silent no-op if one ever forgets.
      watchIngressWithoutClass = true

      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
      }
    }
  })]
}

# --- Sealed Secrets --------------------------------------------------------
# Makes the cluster reproducible from git alone.
#
# ArgoCD can only sync what lives in the repo, but a raw Kubernetes Secret must
# never be committed -- it is base64, which is encoding, not encryption. This
# controller holds an RSA keypair: `kubeseal` encrypts with the public key, and
# only this controller (with the private key, which never leaves the cluster)
# can decrypt. The ENCRYPTED blob is safe to commit to a public repo.
#
# The controller unseals a SealedSecret into a normal Secret in the same
# namespace, so k8s/deployment.yaml keeps reading `ci-triage-secrets` unchanged.
#
# NOTE: the chart moved from the bitnami-labs org to bitnami; the old
# bitnami-labs.github.io index now 404s.
resource "helm_release" "sealed_secrets" {
  name       = "sealed-secrets"
  repository = "https://bitnami.github.io/sealed-secrets"
  chart      = "sealed-secrets"
  version    = var.sealed_secrets_chart_version

  namespace        = "kube-system"
  create_namespace = false

  timeout = 300
  wait    = true

  values = [yamlencode({
    # kubeseal looks for a controller called "sealed-secrets-controller" in
    # kube-system by default. Renaming the release to match means `kubeseal`
    # works with no extra flags.
    #
    # The key is `fullnameOverride`. Helm SILENTLY IGNORES unknown values keys,
    # so a typo here produces no error -- just a controller under the default
    # name and a confusing "cannot find controller" from kubeseal later.
    fullnameOverride = "sealed-secrets-controller"

    resources = {
      requests = { cpu = "20m", memory = "64Mi" }
    }
  })]
}

# --- ArgoCD ----------------------------------------------------------------
# The bootstrap paradox: ArgoCD cannot install itself. Terraform does it once,
# here, and then control inverts -- from Stage 4 on, the cluster pulls its own
# app config from git and Terraform never touches k8s/ again.
resource "helm_release" "argocd" {
  count = var.install_argocd ? 1 : 0

  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  namespace        = "argocd"
  create_namespace = true

  timeout = 900
  wait    = true

  values = [yamlencode({
    # Serve plain HTTP: TLS is terminated at the ingress. Without this the
    # server redirects to HTTPS and you get a redirect loop behind nginx.
    configs = {
      params = {
        "server.insecure" = true
      }
    }

    # Trim components this project does not use. Each is a Deployment that
    # would otherwise sit idle consuming laptop memory.
    dex           = { enabled = false } # SSO
    notifications = { enabled = false } # Slack/webhook alerts

    server = {
      ingress = {
        enabled          = true
        ingressClassName = "nginx"
        hostname         = var.argocd_hostname
      }
    }
  })]

  # ArgoCD's ingress is meaningless until something serves it.
  depends_on = [helm_release.ingress_nginx]
}
