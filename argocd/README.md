# ArgoCD — Stage 4

GitOps layer. ArgoCD runs inside the cluster and continuously reconciles it
against this repository.

## The app-of-apps pattern

```
Terraform (02-platform)
  └─ installs ArgoCD, then creates ONE object: the "root" Application
       │
       ▼
  root Application  ──watches──▶  argocd/applications/
       │
       ▼
  ci-triage-bot Application  ──watches──▶  k8s/
       │
       ▼
  Namespace · Deployment · Service · Ingress · SealedSecret
```

Terraform hands ArgoCD a single pointer and stops. Adding a second service
later means committing one more file to `argocd/applications/` — no Terraform
change, no `kubectl apply`.

## Why Terraform creates the root Application via Helm `extraObjects`

An `Application` is a custom resource, so its CRD must exist before one can be
created. Terraform's `kubernetes_manifest` validates against the API at *plan*
time, which fails on a clean run because ArgoCD's CRDs are not installed yet.

Rendering the root Application through the ArgoCD Helm release avoids this:
Helm installs the CRDs and the object in the same operation, in the right
order. Same class of ordering problem that split the Terraform into two layers.

## Sync policy

Both Applications run with:

| Setting | Effect |
|---|---|
| `automated` | Sync on git change without human approval |
| `prune: true` | Delete resources removed from git — otherwise git is append-only |
| `selfHeal: true` | Revert manual `kubectl` edits back to what git says |

`selfHeal` is the headline behaviour. Delete the Deployment by hand and ArgoCD
puts it back within minutes, because git — not the cluster — is the source of
truth.

## Secrets

`k8s/sealedsecret.yaml` is encrypted with the Sealed Secrets controller's public
key and is safe in a public repo. Only the controller holds the private key, and
it never leaves the cluster. It unseals into a normal Secret named
`ci-triage-secrets`, which `k8s/deployment.yaml` consumes unchanged.

To rotate the key:

```bash
kubectl -n ci-triage create secret generic ci-triage-secrets \
  --from-env-file=.env --dry-run=client -o yaml \
  | kubeseal --format yaml \
      --controller-name sealed-secrets-controller \
      --controller-namespace kube-system \
  > k8s/sealedsecret.yaml
git commit -am "chore: rotate OpenRouter key" && git push
```

ArgoCD picks it up on its own. The plaintext is piped and never written to disk.

**Caveat:** sealed values are bound to the controller's keypair. Destroying the
cluster generates a new keypair, so `sealedsecret.yaml` must be re-sealed after
a rebuild. The committed blob is not portable across clusters.

## Migrating an existing hand-made Secret

Sealed Secrets refuses to adopt a Secret it did not create:

```
failed update: Resource "ci-triage-secrets" already exists
and is not managed by SealedSecret
```

This is a safety feature, not a bug — it prevents the controller clobbering a
Secret owned by something else. Hit during the Stage 4 migration, because the
Secret created imperatively in Stage 2 was still present.

Fix: delete the hand-made Secret so the controller can create its own.

```bash
kubectl -n ci-triage delete secret ci-triage-secrets
kubectl -n kube-system rollout restart deploy/sealed-secrets-controller
```

The restart matters. After deleting the Secret the controller kept reporting
"already exists" from a stale cache, and annotating the SealedSecret did not
clear it. A restart forces a full reconcile and the Secret reappears in ~2s.

Confirm the Secret is now derived from git rather than from a human:

```bash
kubectl -n ci-triage get secret ci-triage-secrets \
  -o jsonpath='{.metadata.ownerReferences[0].kind}'   # -> SealedSecret
```

## Useful commands

```bash
kubectl -n argocd get applications                      # sync + health status
kubectl -n argocd describe application ci-triage-bot    # why it is out of sync
```

UI: <http://argocd.localtest.me:8080> — user `admin`

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## What is NOT solved yet

The image. ArgoCD syncs *manifests* from git, not images from your laptop.
`ci-triage-bot:local` is still built locally and side-loaded with `kind load`,
and because that tag is mutable, `rollout restart` is still required after a
rebuild. Stage 5 fixes this with immutable `sha-<commit>` tags in GHCR.
