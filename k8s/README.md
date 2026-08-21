# Kubernetes manifests — Stage 2

Deploys the CI Triage Bot to a local `kind` cluster. Applied by hand here;
ArgoCD takes over syncing these same files in Stage 4.

## Files

| File | Notes |
|---|---|
| `namespace.yaml` | `ci-triage` namespace |
| `deployment.yaml` | 2 replicas, 3 probes, resource limits, hardened securityContext |
| `service.yaml` | ClusterIP — internal only; the Ingress is the front door |
| `ingress.yaml` | **Inert until Stage 3** installs ingress-nginx |
| `secret.example.yaml` | Template. Never contains a real key. |
| `kustomization.yaml` | Entry point: `kubectl apply -k k8s/` |

## First-time setup

```bash
kind create cluster --config kind/cluster.yaml
docker build -t ci-triage-bot:local ./backend
kind load docker-image ci-triage-bot:local --name ci-triage   # required: no registry
kubectl apply -f k8s/namespace.yaml

# Secret is created from .env, out of band. It is NOT in git.
kubectl -n ci-triage create secret generic ci-triage-secrets \
  --from-env-file=.env --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -k k8s/
kubectl -n ci-triage rollout status deploy/ci-triage-bot
```

## Reaching the app

Until ingress-nginx exists (Stage 3):

```bash
kubectl -n ci-triage port-forward svc/ci-triage-bot 8000:80
# -> http://localhost:8000
```

After Stage 3: <http://ci-triage.localtest.me:8080>

## Redeploying after a code change

`kind load` replaces the image, but the running pods keep the old one — the tag
did not change, so Kubernetes sees nothing to do:

```bash
docker build -t ci-triage-bot:local ./backend
kind load docker-image ci-triage-bot:local --name ci-triage
kubectl -n ci-triage rollout restart deploy/ci-triage-bot
```

That `rollout restart` is a workaround for a mutable tag, and it is exactly the
problem Stage 5 solves properly: build immutable `sha-<commit>` tags, push to a
registry, and let the tag change in git drive the deploy.

## Gotchas already handled

- **`imagePullPolicy: IfNotPresent`** — `Always` would send Kubernetes to Docker
  Hub for `ci-triage-bot:local`, which does not exist there → `ImagePullBackOff`.
- **Immutable selectors** — `spec.selector` cannot be edited after creation.
  Changing it requires deleting and recreating the Deployment.
- **`readOnlyRootFilesystem`** — anything needing scratch space needs an explicit
  volume. `/tmp` has an emptyDir for this reason.
- **Secrets are base64, not encrypted.** Decode with `base64 -d`. This is why the
  real Secret stays out of git.
