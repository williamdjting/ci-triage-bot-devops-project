# Terraform — Stage 3

Provisions the local cluster and the platform services that sit on it.

## Why two layers instead of one

A single root module hits a genuine Terraform limitation: the `kubernetes` and
`helm` providers need an API endpoint to talk to, but that endpoint does not
exist until the `kind_cluster` resource has been created. Terraform configures
providers *before* it applies resources, so a one-module version fails on a
clean run with "Provider configuration is not known at plan time" and only
works if you already have a cluster — which defeats the purpose.

Splitting on that seam is also how real setups are built: cluster lifecycle and
platform services change at different rates, and separate state files mean a
mistake in one cannot destroy the other.

| Layer | Owns | Provider |
|---|---|---|
| `01-cluster/` | The kind cluster: nodes, port mappings, K8s version | `tehcyx/kind` |
| `02-platform/` | ingress-nginx, ArgoCD, sealed-secrets, ArgoCD root Application | `helm`, `kubernetes` |

## What Terraform does NOT own

**The application.** No Deployment, Service, or Ingress for the triage bot
appears anywhere in here. Terraform stops at the platform boundary.

The single exception is the ArgoCD **root Application** — one pointer at
`argocd/applications/` in git, rendered through the ArgoCD chart's
`extraObjects`. That is the entire handoff. After creating it, Terraform never
touches an application manifest again.

That split is the whole design: Terraform for things that change monthly and
need credentials, ArgoCD for things that change every commit.

## Usage

```bash
# Layer 1 -- the cluster
cd terraform/01-cluster
terraform init
terraform apply

# Layer 2 -- the platform (context defaults to layer 1's output)
cd ../02-platform
terraform init
terraform apply
```

There is no third step for the application. Layer 2 installs ArgoCD and points
it at this repo, and ArgoCD deploys the app on its own, pulling the image from
GHCR.

The one thing that does not survive a rebuild is the sealed secret — a new
cluster means a new keypair, so re-seal and push:

```bash
cd ../..
kubectl -n ci-triage create secret generic ci-triage-secrets \
  --from-env-file=.env --dry-run=client -o yaml \
  | kubeseal --format yaml \
      --controller-name sealed-secrets-controller \
      --controller-namespace kube-system \
  > k8s/sealedsecret.yaml
git commit -am "chore: re-seal for new cluster" && git push
```

- App: <http://ci-triage.localtest.me:8080>
- ArgoCD: <http://argocd.localtest.me:8080>

ArgoCD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## Teardown

```bash
cd terraform/02-platform && terraform destroy
cd ../01-cluster      && terraform destroy
```

Destroy in reverse order. Layer 2's state references a cluster layer 1 owns; if
layer 1 goes first, layer 2's destroy has no API server to talk to and hangs.

## Notes

- **`kind/cluster.yaml` is now duplicated** in `01-cluster/main.tf`. The kind
  provider takes its config as HCL, not a file path. Terraform is the source of
  truth; the YAML is the manual escape hatch. Change both or delete the YAML.
- **State is local and gitignored.** `terraform.tfstate` holds every resource
  attribute in plaintext. A team would use a remote backend (S3 + DynamoDB, GCS,
  Terraform Cloud) for sharing and locking.
- **The ArgoCD admin password is not a Terraform output** on purpose. Reading
  that Secret into Terraform would persist the password in state forever.
- **Chart versions are pinned** in `variables.tf`. Unpinned charts mean two
  people running the same config get different clusters.
