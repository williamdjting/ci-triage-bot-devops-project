# Kubernetes manifests — Stage 2

The desired state of the application. **These files are applied by ArgoCD, not
by you** — see `argocd/README.md`. The manual commands below are for debugging
a broken cluster, not for normal use.

## Files

| File | Notes |
|---|---|
| `namespace.yaml` | `ci-triage` namespace |
| `deployment.yaml` | 2 replicas, 3 probes, resource limits, hardened securityContext |
| `service.yaml` | ClusterIP — internal only; the Ingress is the front door |
| `ingress.yaml` | External routing; served by ingress-nginx |
| `secret.example.yaml` | Template. Never contains a real key. |
| `kustomization.yaml` | Entry point, and the single place the image tag lives |

## Normal operation

Nothing here is applied by hand. To deploy a change:

```bash
git commit -am "fix: ..." && git push
```

CI builds the image, pushes it to GHCR as `sha-<commit>`, and rewrites `newTag`
in `kustomization.yaml`. ArgoCD sees the commit and rolls it out.

## The image

`deployment.yaml` names `ci-triage-bot:local`, but that is only a **match key**.
`kustomization.yaml` overrides it:

```yaml
images:
  - name: ci-triage-bot
    newName: ghcr.io/williamdjting/ci-triage-bot
    newTag: sha-<commit>     # rewritten by CI
```

Confirm what is actually deployed:

```bash
kubectl -n ci-triage get deploy ci-triage-bot \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

The tag names the commit, so the answer is unambiguous.

## Reaching the app

<http://ci-triage.localtest.me:8080> — `localtest.me` is public DNS that always
resolves to `127.0.0.1`, so no `/etc/hosts` editing is required.

If ingress-nginx is broken, fall back to:

```bash
kubectl -n ci-triage port-forward svc/ci-triage-bot 8000:80
```

## Manual apply (debugging only)

If ArgoCD itself is broken and you need the app running:

```bash
kubectl apply -k k8s/
```

This pulls the GHCR image named in `kustomization.yaml`; no `kind load` is
needed. Expect ArgoCD to revert any hand-edit once it recovers — `selfHeal` is
the system working correctly, not fighting you.

## Gotchas already handled

- **`imagePullPolicy: IfNotPresent`** — correct because tags are immutable: a
  tag already on the node is guaranteed to be the right image, so re-pulling is
  waste. (Before Stage 5 this setting was required for a different reason —
  `:local` existed only inside the kind nodes.)
- **Images must be multi-arch.** CI runners are amd64; Apple Silicon kind nodes
  are arm64. An amd64-only image fails with `no match for platform in manifest`.
- **Immutable selectors** — `spec.selector` cannot be edited after creation.
  Changing it requires deleting and recreating the Deployment.
- **`readOnlyRootFilesystem`** — anything needing scratch space needs an explicit
  volume. `/tmp` has an emptyDir for this reason.
- **Secrets are base64, not encrypted.** Decode with `base64 -d`. This is why the
  real Secret stays out of git.
- **`rollout status` could once report success on a stale deploy.** With the
  mutable `:local` tag, rebuilding left the Deployment spec identical, so
  Kubernetes did nothing while every command exited 0. Immutable `sha-<commit>`
  tags make this impossible to express — kept here because the failure was
  completely silent, and the same trap exists in any setup using mutable tags.
