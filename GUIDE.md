# Infrastructure Guide

Everything built so far for the CI Failure Triage Bot: what exists, why it is
shaped this way, and what comes next.

**Status:** Stages 1–4 complete and running. Stage 5 not started.

---

## 1. The application

A single stateless FastAPI service. You paste a raw CI log, an LLM returns
structured triage (classification, failing step, key error line, explanation,
suggested action).

| Property | Value | Why it matters for infra |
|---|---|---|
| Services | 1 | Nothing to orchestrate between components |
| State | None | Any replica can serve any request; scaling is trivial |
| Database | None | No volumes, backups, or migrations |
| External deps | OpenRouter API | One egress dependency |
| Secrets | `OPENROUTER_API_KEY` | One secret, and it must never reach git |
| Frontend | Static HTML, no build | Served by the same container |

This is close to the simplest realistic infrastructure target, which is the
point: nothing about the app fights the infrastructure work.

---

## 2. Where things stand

| Stage | Scope | Status |
|---|---|---|
| 1 | Docker — image + local run | Done |
| 2 | Kubernetes — manifests on kind | Done |
| 3 | Terraform — cluster + platform | Done |
| 4 | ArgoCD — GitOps sync + sealed secrets | Done |
| 5 | CI — build, push, auto-deploy | **Not started** |

Live URLs (while the cluster is up):

- App: <http://ci-triage.localtest.me:8080>
- ArgoCD: <http://argocd.localtest.me:8080>

`*.localtest.me` is a public DNS name that always resolves to `127.0.0.1`, so
no `/etc/hosts` editing is needed.

---

## 3. Architecture as it stands

### The layer stack

```
┌──────────────────────────────────────────────────────────────┐
│  STAGE 4   ArgoCD, running continuously inside the cluster   │
│            root Application ──▶ argocd/applications/         │
│                             ──▶ ci-triage-bot ──▶ k8s/       │
├──────────────────────────────────────────────────────────────┤
│  STAGE 2   k8s/   Deployment · Service · Ingress ·           │
│                   SealedSecret — now synced by ArgoCD,       │
│                   no longer applied by hand                  │
├──────────────────────────────────────────────────────────────┤
│  STAGE 3   terraform/02-platform  ingress-nginx, ArgoCD,     │
│                                   sealed-secrets             │
│            terraform/01-cluster   kind cluster, 3 nodes      │
├──────────────────────────────────────────────────────────────┤
│  STAGE 1   backend/Dockerfile → ci-triage-bot:local          │
└──────────────────────────────────────────────────────────────┘
```

### The request path

```
  browser
    │  http://ci-triage.localtest.me:8080
    ▼
  macOS localhost:8080
    │  kind extraPortMapping  (host 8080 → node 80)
    ▼
  control-plane node :80
    │  ingress-nginx controller, hostPort, pinned here by
    │  nodeSelector ingress-ready=true
    ▼
  Ingress rule  host: ci-triage.localtest.me
    ▼
  Service ci-triage-bot  (ClusterIP :80)
    ▼
  Pod :8000  ── uvicorn ──▶ OpenRouter API
   (2 replicas, one on each worker node)
```

Two details make this work on a laptop, and both are kind-specific:

- **`extraPortMappings`** in the cluster config. A kind node is a Docker
  container; without an explicit port mapping nothing inside it is reachable
  from macOS.
- **`hostPort` on the ingress controller** rather than a `LoadBalancer`
  Service. kind has no cloud load balancer, so a `LoadBalancer` Service would
  sit in `<pending>` forever.

### Cluster topology

```
  ci-triage-control-plane    label ingress-ready=true
                             ports 80→8080, 443→8443
                             runs: ingress-nginx, ArgoCD (5 pods)

  ci-triage-worker           runs: ci-triage-bot replica 1
  ci-triage-worker2          runs: ci-triage-bot replica 2
```

Two workers exist specifically so you can watch the scheduler spread replicas
across nodes rather than stacking them.

---

## 4. Stage 1 — Docker

**Question it answers: what *is* this app, and what does it need to run?**

The problem is reproducibility. Before Docker, running the app meant a README
of human steps — install Python 3.12, make a venv, `pip install`, set env vars.
Every step is a chance for two machines to differ. The Dockerfile replaces those
instructions with a *build* whose output is one immutable artifact.

**Files:** `backend/Dockerfile`, `backend/.dockerignore`, `docker-compose.yml`

| Decision | Reason |
|---|---|
| Multi-stage build | Build stage needs `pip` and toolchain; runtime does not. Only the finished venv is copied forward. 62MB final image. |
| `COPY requirements.txt` before code | Layer caching. Editing `main.py` does not reinstall dependencies. |
| Non-root uid 10001 | A compromised app is not root inside the container. |
| `.dockerignore` excludes `.env` | A secret in the build context can end up in an image layer permanently. |
| `HEALTHCHECK` + `/healthz` | Gives something outside the process a cheap way to ask "alive?" |

**App change made:** `/healthz` was added to `backend/app/main.py`. It does no
I/O and never calls OpenRouter — deliberately. Wiring an upstream dependency
into a liveness probe means an OpenRouter outage would make Kubernetes restart
healthy pods in a loop.

**What Stage 1 does not do:** keep the app running. One container, one machine,
no scaling, no traffic routing, no zero-downtime deploys.

---

## 5. Stage 2 — Kubernetes

**Question it answers: how does that artifact run, stay running, and get reached?**

The shift is imperative → declarative. You stop saying "start this container"
and start saying "two of these should always exist." A controller continuously
works to make reality match.

**Files:** `k8s/` (namespace, deployment, service, ingress, secret template,
kustomization, README) and `kind/cluster.yaml`

| Manifest | Declares |
|---|---|
| `deployment.yaml` | 2 replicas, 3 probes, resource limits, hardened securityContext |
| `service.yaml` | Stable internal address — pod IPs change constantly, this does not |
| `ingress.yaml` | External routing rules |
| Secret | API key, injected at runtime, **not in git** |
| `kustomization.yaml` | Single entry point: `kubectl apply -k k8s/` |

**Three probes, three different questions:**

| Probe | Asks | On failure |
|---|---|---|
| `startupProbe` | Finished booting? | Gates the other two |
| `readinessProbe` | Should it get traffic? | Removed from Service, **not** restarted |
| `livenessProbe` | Is it wedged? | Container restarted |

Docker's single `HEALTHCHECK` cannot distinguish these.

**Security is enforced by the cluster, not trusted from the image.**
`runAsNonRoot: true` means the pod refuses to start if the image ever regressed
to root. Verified inside a live pod: uid 10001, `touch /` fails
(`readOnlyRootFilesystem`), `/tmp` writable via an explicit emptyDir.

**Zero-downtime deploys:** `maxUnavailable: 0, maxSurge: 1` brings a new pod up
and proves it ready *before* retiring an old one.

**Secrets:** the real Secret is created out of band from `.env` and gitignored.
Only `secret.example.yaml` is committed. Kubernetes Secrets are base64, which is
*encoding, not encryption* — anyone with repo read access could `base64 -d` a
committed one. Stage 4 forces a proper answer, since ArgoCD can only sync what
lives in git (Sealed Secrets or External Secrets Operator).

---

## 6. Stage 3 — Terraform

**Question it answers: where does the cluster itself come from?**

**Files:** `terraform/01-cluster/`, `terraform/02-platform/`, `terraform/README.md`

### Why two root modules instead of one

A technical necessity, not style. The `kubernetes` and `helm` providers need an
API endpoint, but that endpoint does not exist until `kind_cluster` is created —
and Terraform configures providers *before* it applies resources. A single
module fails on a clean run with "Provider configuration not known at plan
time," and only works if a cluster already exists, which defeats the purpose.

The split has a second benefit: separate state files mean a bad plan in layer 2
physically cannot destroy your cluster.

| Layer | Owns | Provider | Apply time |
|---|---|---|---|
| `01-cluster` | Nodes, K8s version, port mappings | `tehcyx/kind` 0.11 | ~32s |
| `02-platform` | ingress-nginx 4.15.1, ArgoCD 10.4.1 | `helm` 3.2, `kubernetes` 2.38 | ~2m11s |

**Teardown reverses the order.** Destroy layer 2 first — layer 1 removes the API
server that layer 2's destroy needs to talk to.

### What ingress-nginx changed

The Ingress written in Stage 2 was **inert for the whole stage**. An Ingress is
only a *request*; without a controller watching for them, nothing acts on it.
Installing the controller is what turned `ci-triage.localtest.me:8080` from
nothing into a working URL, and removed the need for `kubectl port-forward`.

### The bootstrap paradox

ArgoCD cannot install itself — something outside the cluster must create the
cluster and put ArgoCD in it. Terraform does that once. From then on control
inverts: the cluster pulls its own configuration from git.

### What Terraform deliberately does NOT own

**The application.** No Deployment, Service, or Ingress for the bot appears
anywhere in `terraform/`. Terraform stops at the platform boundary.

---

## 7. Stage 4 — ArgoCD

**Question it answers: how does the cluster stay in sync with git, without a human?**

**Files:** `argocd/applications/ci-triage-bot.yaml`, `argocd/README.md`,
`k8s/sealedsecret.yaml`

### App-of-apps

Terraform creates exactly one application-related object — a root `Application`
pointing at `argocd/applications/` — and stops. That directory holds the real
Applications, so adding a second service later is one committed file, not a
Terraform change.

```
Terraform ──creates──▶ root Application
                          └─watches─▶ argocd/applications/
                                         └─▶ ci-triage-bot
                                                └─watches─▶ k8s/
```

The root Application is rendered through the ArgoCD Helm chart's `extraObjects`
rather than a `kubernetes_manifest` resource. An `Application` is a custom
resource, and `kubernetes_manifest` validates against the API at *plan* time,
which fails on a clean run because ArgoCD's CRDs do not exist yet. Helm installs
the CRD and the object in one ordered operation — the same ordering problem that
split the Terraform into two layers.

### Self-healing

Both Applications run `automated` with `prune: true` and `selfHeal: true`.
Verified by deleting the Deployment by hand: **ArgoCD restored it in ~10
seconds** with no human action. Git, not the cluster, is the source of truth.

`prune` matters as much as `selfHeal` — without it, git becomes append-only:
you can add resources but removing them from the repo never removes them from
the cluster.

### Sealed secrets

`k8s/sealedsecret.yaml` holds the OpenRouter key encrypted with the Sealed
Secrets controller's public key. Safe to commit to a public repo — only the
in-cluster private key can open it, and that key never leaves the cluster. The
controller unseals it into a normal Secret named `ci-triage-secrets`, which
`deployment.yaml` reads unchanged.

This is what makes the cluster reproducible from git alone, and it exists
because ArgoCD can only sync what lives in the repo.

---

## 8. The ownership boundary

This is the core design idea, and it falls out of one distinction:

> **Terraform runs when you run it. ArgoCD runs always.**

Terraform's view of the world is a snapshot taken at `apply` time. If someone
`kubectl edit`s a Deployment at 2am, Terraform does not know until the next
`plan`. ArgoCD is a controller inside the cluster re-checking against git every
few minutes, so it notices that drift and can revert it.

| | Owns | Change rate | Model |
|---|---|---|---|
| **Terraform** | Cluster, networking, registries, IAM, and ArgoCD itself | Weeks/months | **Push** — you run `apply` |
| **K8s manifests** | Desired state of the app. Just YAML in git | Every commit | — |
| **ArgoCD** | Making the cluster match those manifests | Continuous | **Pull** — it watches the repo |

Rule of thumb: needs credentials and changes rarely → Terraform. Changes every
commit → ArgoCD.

**Note:** In production, Helm or ArgoCD normally own the app layer while
Terraform owns cluster and cloud resources. This project follows that split
from Stage 4 onward.

---

## 9. Running it from scratch

Requires: Docker Desktop running, `terraform`, `kubectl`, `kind`, and a `.env`
containing `OPENROUTER_API_KEY`.

```bash
# Layer 1 — the cluster
cd terraform/01-cluster && terraform init && terraform apply

# Layer 2 — the platform
cd ../02-platform && terraform init && terraform apply

# The app -- ArgoCD deploys it from git on its own. Only the IMAGE is manual,
# because ArgoCD syncs manifests, not images from your laptop. (Stage 5.)
cd ../..
docker build -t ci-triage-bot:local ./backend
kind load docker-image ci-triage-bot:local --name ci-triage
kubectl -n ci-triage rollout restart deploy/ci-triage-bot   # mutable tag
```

Re-seal the secret after a cluster rebuild — a new cluster means a new keypair,
so the committed blob cannot be decrypted:

```bash
kubectl -n ci-triage create secret generic ci-triage-secrets \
  --from-env-file=.env --dry-run=client -o yaml \
  | kubeseal --format yaml \
      --controller-name sealed-secrets-controller \
      --controller-namespace kube-system \
  > k8s/sealedsecret.yaml
git commit -am "chore: re-seal for new cluster" && git push
```

Teardown (reverse order):

```bash
cd terraform/02-platform && terraform destroy
cd ../01-cluster        && terraform destroy
```

ArgoCD login — user `admin`:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## 10. Gotchas — all of these actually happened

**`rollout status` can report success on a stale deploy.**
Observed 2026-08-29: pods ran a 7-day-old image while every command exited 0 and
`rollout status` printed "successfully rolled out". The Deployment spec
(`image: ci-triage-bot:local`) never changed, so Kubernetes correctly did
nothing — it compares the *tag string*, never image contents. A green rollout is
not proof you deployed what you built. To see what is really running:

```bash
kubectl -n ci-triage get pods \
  -o custom-columns='POD:.metadata.name,IMAGE_ID:.status.containerStatuses[0].imageID'
```

kind names loaded images `import-<YYYY-MM-DD>`, so the date reveals the build.
`rollout restart` is the workaround; **Stage 5 removes the need for it.**

**Terraform cannot manage resources it did not create.**
The Stage 2 cluster was made with the `kind` CLI, so it was invisible to
Terraform's state, and `terraform apply` would have failed on the name
collision. Fixed by deleting it and rebuilding from code. Once a resource is
under Terraform, stop touching it by hand — here it fails loudly, in a cloud
account it fails at 3am.

**A config never applied from scratch is untested.**
Rebuilding immediately exposed a bug: the kind provider writes a kubeconfig to
`terraform/01-cluster/ci-triage-config` containing `client-certificate-data` and
`client-key-data` — cluster-admin credentials in plaintext — untracked in the
repo. The `.gitignore` had been written before any apply, so it covered
`*.tfstate` but not a file only the provider creates. You cannot fully gitignore
infrastructure you have not run.

**Sealed Secrets will not adopt a Secret it did not create.**
Migrating from the imperative Stage 2 Secret produced
`failed update: Resource "ci-triage-secrets" already exists and is not managed
by SealedSecret`. That is a safety feature, not a bug. Deleting the hand-made
Secret is the fix — but the controller then kept reporting "already exists"
from a stale cache, and annotating the SealedSecret did not clear it. A
controller restart forces a full reconcile and the Secret reappears in ~2s.

**Helm silently ignores unknown values keys.**
`fullnameSelector` is not a real key in the sealed-secrets chart. There was no
error — the controller simply installed under its default name, which is not
where `kubeseal` looks. The correct key is `fullnameOverride`. Verify a key
exists in the chart's `values.yaml` before relying on it.

**Helm chart repositories move.** The sealed-secrets chart migrated from the
`bitnami-labs` org to `bitnami`; `bitnami-labs.github.io/sealed-secrets` now
returns 404. Bitnami's own catalog carries a much older version (app 0.31.0)
than the current chart (0.39.1), so picking the wrong source silently pins you
to a stale controller.

**`imagePullPolicy` must not be `Always`.**
`ci-triage-bot:local` exists only inside the kind nodes. `Always` sends
Kubernetes to Docker Hub and yields `ImagePullBackOff`.

**`spec.selector` is immutable.**
Changing it requires deleting and recreating the Deployment — an outage in
production. Keep selector labels minimal and never touch them.

**`kind create cluster` errors if the cluster already exists,** and a kind
cluster survives a Docker Desktop restart. Guard it:
`kind get clusters | grep -q ci-triage || kind create cluster ...`

**`readOnlyRootFilesystem` blocks all writes.** Anything needing scratch space
needs an explicit volume. `/tmp` has an emptyDir for this.

---

## 11. Known limitations

- **`kind/cluster.yaml` is duplicated** in `terraform/01-cluster/main.tf`. The
  kind provider takes HCL, not a file path. Terraform is the source of truth;
  the YAML is the manual escape hatch. Change both or delete the YAML.
- **Terraform state is local and gitignored.** A team would use a remote backend
  (S3 + DynamoDB, GCS, Terraform Cloud) for sharing and locking.
- **`:local` is a mutable tag** — the root cause of the stale-deploy trap.
- **No CI.** Nothing builds or tests the image automatically.
- **Sealed values are bound to the controller's keypair.** Destroying the
  cluster generates a new keypair, so `k8s/sealedsecret.yaml` must be re-sealed
  after a rebuild. The committed blob is not portable across clusters.
- **Local only.** No cloud provider, no TLS, no real DNS.

---

## 12. Next steps

### Stage 5 — CI (the only stage left)

GitHub Actions builds the image, pushes to GHCR tagged `sha-<commit>`, and
commits that tag into the manifest. ArgoCD sees the git change and syncs.

This closes the loop and **eliminates the stale-image trap entirely**: immutable
tags mean the Deployment spec genuinely changes on every deploy, so there is no
`rollout restart` to remember and no way to be wrong about what is running.

Fittingly, the CI pipeline will then be producing exactly the kind of failure
logs this application was built to triage.
