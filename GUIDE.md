# Infrastructure Guide

A complete account of the CI Failure Triage Bot and the infrastructure that runs
it: every component, every stage, what each one does, why it exists, and what
would break without it.

**Status:** Stages 1–5 complete. The deployment loop is fully automated.

---

# Part I — The application

## 1. What it does

A web app that triages CI failures with an LLM. You paste raw log output from
GitHub Actions or Jenkins; it returns structured analysis. It does not connect
to any CI system or run builds — pasted logs are the only input.

Given a log, it returns five fields:

| Field | Meaning |
|---|---|
| `classification` | One of `test_failure`, `lint_failure`, `infra_failure`, `config_failure`, `unknown` |
| `failing_step` | The step or job where the failure occurred |
| `key_error_line` | The single most important line in the log |
| `explanation` | Why it failed |
| `suggested_action` | What the developer should do next |

## 2. Code structure

```
backend/
├── app/
│   ├── main.py       FastAPI app: routes, static mounting, startup
│   ├── llm.py        OpenRouter integration and response normalisation
│   ├── schemas.py    Pydantic request/response models
│   └── __init__.py
├── static/
│   └── index.html    Single-page UI, no build step
└── requirements.txt  fastapi, uvicorn, openai, pydantic, python-dotenv
```

**`main.py`** — three routes:

| Route | Purpose |
|---|---|
| `GET /` | Serves `static/index.html` |
| `GET /healthz` | Liveness/readiness probe (added for Stage 1) |
| `POST /api/analyze` | The actual work |

**`llm.py`** — builds a system prompt plus a user message containing the log,
calls OpenRouter with `response_format={"type": "json_object"}` and
`temperature=0.2`, then normalises the returned classification string onto the
enum. Model defaults to `openai/gpt-4o-mini`, overridable via
`OPENROUTER_MODEL`.

**`schemas.py`** — `AnalyzeRequest` (log content, optional provider, step name,
exit code) and `AnalyzeResponse` (the five fields above), with `CIProvider` and
`FailureClassification` enums.

## 3. Why this app is an ideal infrastructure target

| Property | Value | Consequence for infrastructure |
|---|---|---|
| Services | 1 | Nothing to orchestrate between components |
| State | None | Any replica serves any request; scaling is trivial |
| Database | None | No volumes, backups, migrations, or StatefulSets |
| External deps | OpenRouter HTTPS | One egress dependency, no ingress dependencies |
| Secrets | `OPENROUTER_API_KEY` | Exactly one secret to protect |
| Frontend | Static HTML | Served by the same container; no separate build or CDN |
| Startup | ~2 seconds | Fast rollouts, simple probes |

Nothing about the application fights the infrastructure work, which means every
problem encountered was a genuine infrastructure problem rather than an
application quirk.

---

# Part II — Architecture

## 4. The five layers

```
┌───────────────────────────────────────────────────────────────────┐
│ STAGE 5  GitHub Actions                                           │
│          build → smoke test → push to GHCR → write tag to git     │
│          Holds NO cluster credentials. Deploys nothing.           │
├───────────────────────────────────────────────────────────────────┤
│ STAGE 4  ArgoCD, running inside the cluster, continuously         │
│          root Application ──▶ argocd/applications/                │
│                           ──▶ ci-triage-bot ──▶ k8s/              │
├───────────────────────────────────────────────────────────────────┤
│ STAGE 2  k8s/  Namespace · Deployment · Service · Ingress ·       │
│                SealedSecret        (synced by ArgoCD, not by you) │
├───────────────────────────────────────────────────────────────────┤
│ STAGE 3  terraform/02-platform  ingress-nginx, ArgoCD,            │
│                                 sealed-secrets                    │
│          terraform/01-cluster   kind cluster, 3 nodes             │
├───────────────────────────────────────────────────────────────────┤
│ STAGE 1  backend/Dockerfile → ghcr.io/<owner>/ci-triage-bot       │
└───────────────────────────────────────────────────────────────────┘
```

Each layer depends only on the layer beneath it, and each has a single clear
owner. That separation is the design.

## 5. The request path

What happens when someone opens the app in a browser:

```
  browser
    │  http://ci-triage.localtest.me:8080
    │  (localtest.me is public DNS that always resolves to 127.0.0.1,
    │   so no /etc/hosts editing is needed)
    ▼
  macOS localhost:8080
    │  kind extraPortMapping: host 8080 → node container port 80
    ▼
  ci-triage-control-plane node, port 80
    │  ingress-nginx controller, bound via hostPort,
    │  pinned to this node by nodeSelector ingress-ready=true
    ▼
  Ingress rule matches host: ci-triage.localtest.me
    │  proxy-body-size 8m      (CI logs are large; nginx defaults to 1MB)
    │  proxy-read-timeout 120  (LLM calls are slow; default 60s would cut off)
    ▼
  Service ci-triage-bot (ClusterIP :80 → targetPort http)
    │  load-balances across ready endpoints only
    ▼
  Pod :8000  (2 replicas, one per worker node)
    │  uvicorn → FastAPI
    ▼
  OpenRouter API (egress, HTTPS)
    │  key injected as env var from Secret ci-triage-secrets,
    │  which the sealed-secrets controller unsealed from git
```

Two details exist purely because this runs on kind:

- **`extraPortMappings`** — a kind node is a Docker container. Without an
  explicit port mapping, nothing inside it is reachable from macOS.
- **`hostPort` on the controller rather than a `LoadBalancer` Service** — kind
  has no cloud load balancer, so a `LoadBalancer` Service would sit `<pending>`
  forever.

On a real cloud these are replaced by a cloud load balancer and real DNS.
Nothing else in the stack changes.

## 6. The deploy path

What happens when someone pushes a backend change:

```
  git push (backend/**)
    ▼
  GitHub Actions: build image (buildx, amd64 + arm64)
    ▼
  smoke test: run container, assert /healthz 200, / 200, uid 10001
    │  a broken image fails HERE, before it is ever published
    ▼
  push to ghcr.io/<owner>/ci-triage-bot:sha-<commit>   ← immutable tag
    ▼
  rewrite newTag in k8s/kustomization.yaml, commit "chore(deploy): sha-..."
    │  CI's job ends here. It has no cluster credentials.
    ▼
  ArgoCD (polling the repo) sees a new commit
    ▼
  renders k8s/ through Kustomize, diffs against the live cluster
    ▼
  applies the changed Deployment
    ▼
  rolling update: maxUnavailable 0, maxSurge 1
    │  new pod must pass its readiness probe BEFORE an old pod is retired
    ▼
  live
```

No human runs `kubectl`. No CI system holds cluster credentials. The only
action a developer takes is `git push`.

## 7. Cluster topology

```
  ci-triage-control-plane   label: ingress-ready=true
                            ports: 80→8080, 443→8443
                            taint: node-role.kubernetes.io/control-plane
                            runs: ingress-nginx, ArgoCD (5 pods),
                                  sealed-secrets controller, control plane

  ci-triage-worker          runs: ci-triage-bot replica
  ci-triage-worker2         runs: ci-triage-bot replica
```

Two workers exist specifically so the scheduler spreads the replicas rather
than stacking them. The control-plane node carries the port mappings, so
ingress-nginx must be pinned there — which requires both a `nodeSelector` for
the label and a `toleration` for the control-plane taint.

## 8. Complete file inventory

| Path | Purpose |
|---|---|
| `backend/Dockerfile` | Multi-stage build producing the runtime image |
| `backend/.dockerignore` | Excludes venv, caches, and `.env` from the build context |
| `docker-compose.yml` | Local single-container run, no Kubernetes |
| `kind/cluster.yaml` | Manual cluster config (escape hatch; Terraform is authoritative) |
| `k8s/namespace.yaml` | The `ci-triage` namespace |
| `k8s/deployment.yaml` | 2 replicas, 3 probes, resource limits, hardened securityContext |
| `k8s/service.yaml` | ClusterIP; stable internal address |
| `k8s/ingress.yaml` | External routing rules and nginx tuning |
| `k8s/sealedsecret.yaml` | The API key, encrypted. Safe to commit. |
| `k8s/secret.example.yaml` | Template only; never applied |
| `k8s/kustomization.yaml` | Entry point; holds the image tag CI rewrites |
| `k8s/README.md` | Kubernetes-layer runbook |
| `terraform/01-cluster/` | The kind cluster |
| `terraform/02-platform/` | ingress-nginx, ArgoCD, sealed-secrets, root Application |
| `terraform/README.md` | Terraform-layer runbook |
| `argocd/applications/ci-triage-bot.yaml` | The Application syncing `k8s/` |
| `argocd/README.md` | GitOps runbook |
| `.github/workflows/ci.yml` | Build, smoke test, push, tag bump |
| `.env` | **Not in git.** The only input not reproducible from the repo. |

---

# Part III — The stages in detail

Each stage answers one question the previous stage could not.

## 9. Stage 1 — Docker

> **Question: what *is* this application, and what does it need to run?**

### The problem

Before containerisation, running the app meant following prose: install Python
3.12, create a venv, `pip install -r requirements.txt`, set environment
variables, run uvicorn. Every one of those steps is a place where your machine
and a server can diverge — a different Python patch version, a different
OpenSSL, a stale dependency resolved months apart. That divergence is what
"works on my machine" actually means.

### What it does

`backend/Dockerfile` replaces those instructions with a **build**, whose output
is a single immutable artifact containing the interpreter, the dependencies,
and the code frozen together. Anyone with that artifact gets a byte-identical
environment.

### Key decisions

| Decision | Rationale |
|---|---|
| **Multi-stage build** | The build stage needs `pip` and a toolchain; the runtime needs neither. Only the finished virtualenv is copied into the final image. Result: 62MB compressed, and no compiler in production. |
| **`COPY requirements.txt` before the code** | Docker caches layers. Dependencies change rarely, code changes constantly. Copying them separately means editing `main.py` does not reinstall every package — build time drops from minutes to seconds. |
| **Non-root uid 10001** | If the application is compromised, the attacker is not root inside the container. This pairs with the Kubernetes `runAsNonRoot` in Stage 2, which *enforces* what this merely chooses. |
| **`.dockerignore` excludes `.env`** | Anything in the build context can end up in an image layer, and layers are permanent — deleting a file in a later layer does not remove it from the image. A secret that reaches a layer is leaked. |
| **`HEALTHCHECK`** | Gives the container runtime a way to distinguish "process exists" from "process is serving". |

### The application change this required

`/healthz` was added to `backend/app/main.py`. It does no I/O and never calls
OpenRouter — **deliberately**. Wiring an upstream dependency into a health check
means an OpenRouter outage would make Kubernetes conclude your healthy pods are
broken and restart them in a loop, converting a partial degradation into a total
outage.

### Why it matters

Everything above this layer assumes a reproducible artifact. Kubernetes cannot
schedule "some Python code and a README"; ArgoCD cannot roll out a set of
install instructions. The image is the unit that every later stage moves around.

### What Stage 1 deliberately does not do

Keep the app running. Compose offers `restart: unless-stopped` and nothing more:
one container, one machine, no scaling, no traffic routing, no way to deploy a
new version without dropping requests.

---

## 10. Stage 2 — Kubernetes

> **Question: how does that artifact run, stay running, and get reached?**

### The problem

A container that dies stays dead. A single container cannot be upgraded without
downtime. Nothing routes traffic to it, nothing restarts it, nothing notices if
it wedges.

### The conceptual shift

Imperative → declarative. You stop issuing commands ("start this container") and
start describing an end state ("two of these should always exist"). A controller
then works continuously to make reality match the description. This is the idea
that Stage 4 later extends all the way back to git.

### The manifests

| Manifest | What it declares | Why it matters |
|---|---|---|
| `deployment.yaml` | 2 replicas of the image, with probes, limits, security context | The self-healing unit. Node dies → pods rescheduled. |
| `service.yaml` | A stable ClusterIP and DNS name | Pod IPs change on every restart. Nothing should ever address a pod directly. |
| `ingress.yaml` | Host-based external routing | The single front door; the Service stays internal. |
| `sealedsecret.yaml` | The API key, encrypted | Runtime config that must never be in the image. |
| `kustomization.yaml` | The set of resources, plus the image tag | One entry point for both `kubectl apply -k` and ArgoCD. |

### Three probes, three different questions

This is the part most often misunderstood, and getting it wrong causes outages:

| Probe | Asks | On failure | Configured |
|---|---|---|---|
| `startupProbe` | Has it finished booting? | Gates the other two; nothing else runs until this passes | every 2s, 15 failures = 30s budget |
| `readinessProbe` | Should it receive traffic? | Removed from the Service. **Not restarted.** | every 5s, 2 failures |
| `livenessProbe` | Is it wedged beyond recovery? | Container **restarted** | every 10s, 3 failures |

The distinction between readiness and liveness is the important one. A pod that
is briefly busy should stop receiving traffic, not be killed. Using a liveness
probe where a readiness probe belongs turns transient load into a restart storm.
Docker's single `HEALTHCHECK` cannot express this difference at all.

### Security, enforced rather than trusted

Stage 1 *chose* to run as uid 10001. Stage 2 *requires* it:

```yaml
runAsNonRoot: true          # pod refuses to START if the image runs as root
runAsUser: 10001
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities: { drop: ["ALL"] }
seccompProfile: { type: RuntimeDefault }
```

Verified inside a live pod: `id` returns uid 10001, `touch /` fails, and `/tmp`
is writable only because an explicit `emptyDir` is mounted there. If a future
image regressed to root, the pod would not start — the failure is loud and
immediate rather than silent and permanent.

### Zero-downtime rollouts

```yaml
maxUnavailable: 0   # never drop below the replica count
maxSurge: 1         # bring up one extra, prove it ready, then retire an old one
```

This is not theoretical. During Stage 5 a bad image tag reached the cluster; the
new pod went `ImagePullBackOff` and **the app never went down**, because
`maxUnavailable: 0` meant the old pods were never retired for a replacement that
never became ready.

### Resource requests and limits

```yaml
requests: { cpu: 50m,  memory: 128Mi }   # what the scheduler reserves
limits:   { cpu: 500m, memory: 256Mi }   # hard ceiling
```

Requests drive scheduling — this is why the two replicas landed on different
worker nodes. Limits cap consumption; exceeding the memory limit is an
`OOMKill`, not throttling. Without requests, the scheduler is guessing, and one
noisy workload can starve everything on a node.

### Why it matters

This layer is what makes the application *operable*: survivable, upgradeable,
observable, and reachable. It is also the layer that becomes the GitOps payload
in Stage 4 — these exact files are what ArgoCD syncs.

---

## 11. Stage 3 — Terraform

> **Question: where does the cluster itself come from?**

### The problem

Stages 1 and 2 both assume a cluster exists. Creating one by hand is the same
"works on my machine" problem one level down: undocumented, unrepeatable, and
impossible to hand to someone else.

### Why two root modules

This is a genuine technical constraint, not a stylistic preference.

The `kubernetes` and `helm` providers need an API endpoint to talk to. That
endpoint does not exist until the `kind_cluster` resource has been created. But
Terraform **configures providers before it applies resources**. A single module
therefore fails on a clean run with "Provider configuration not known at plan
time," and only appears to work if a cluster already happens to exist — which
defeats the entire purpose.

Splitting on that seam makes layer 2's endpoint a plain static string that
always exists. It also mirrors production practice: cluster lifecycle and
platform services change at different rates, and separate state files mean a
mistake in one cannot destroy the other.

| Layer | Owns | Provider | Apply time |
|---|---|---|---|
| `01-cluster` | Nodes, Kubernetes version, port mappings, labels | `tehcyx/kind` 0.11 | ~32s |
| `02-platform` | ingress-nginx 4.15.1, ArgoCD 10.4.1, sealed-secrets 2.19.3 | `helm` 3.2, `kubernetes` 2.38 | ~2m30s |

**Teardown reverses the order.** Destroy layer 2 first — layer 1 removes the API
server that layer 2's destroy needs to talk to.

### What each layer contains

**`01-cluster`** — one `kind_cluster` resource mirroring `kind/cluster.yaml`:
three nodes, the `ingress-ready=true` label, `extraPortMappings` for 80 and 443,
and a **pinned node image** (`kindest/node:v1.36.1`). Pinning matters: leaving
it unset means the Kubernetes version silently follows whatever kind CLI the
operator happens to have installed.

**`02-platform`** — three Helm releases plus the ArgoCD root Application:

- **ingress-nginx** — the piece that made the Stage 2 Ingress real. An Ingress
  is only a *request*; without a controller watching for Ingress objects,
  nothing acts on it. The Ingress sat inert for the whole of Stage 2. Installing
  the controller is what turned `ci-triage.localtest.me:8080` into a working URL
  and removed the need for `kubectl port-forward`.
- **ArgoCD** — installed here because of the **bootstrap paradox**: ArgoCD
  cannot install itself. Something outside the cluster must create the cluster
  and place ArgoCD in it. Terraform does that once, and then control inverts.
- **sealed-secrets** — the controller holding the RSA private key that makes
  committing an encrypted secret safe.

### Why it matters

The cluster becomes reproducible and reviewable. `terraform destroy` followed by
`terraform apply` rebuilds it identically, and a change to the cluster is a diff
someone can read in a pull request rather than a command someone ran once.

### What Terraform deliberately does not own

**The application.** No Deployment, Service, or Ingress for the bot appears
anywhere in `terraform/`. Terraform stops at the platform boundary. The single
exception is the ArgoCD root Application — one pointer, described below.

---

## 12. Stage 4 — ArgoCD

> **Question: how does the cluster stay in sync with git, without a human?**

### The problem

After Stage 3 the cluster was reproducible but the *application* still was not.
Deploying meant a seven-command sequence run by hand, the Secret existed only
because someone typed a `kubectl create secret`, and any manual `kubectl edit`
silently diverged from the repo with nothing to detect it.

### The app-of-apps pattern

```
Terraform ──creates──▶ root Application
                          └─watches─▶ argocd/applications/
                                         └─▶ ci-triage-bot Application
                                                └─watches─▶ k8s/
                                                     └─▶ Namespace
                                                         Deployment
                                                         Service
                                                         Ingress
                                                         SealedSecret
```

Terraform creates **exactly one** application-related object — a pointer at a
directory — and stops. Adding a second service later means committing one file
to `argocd/applications/`: no Terraform change, no `kubectl apply`, no cluster
credentials.

### An implementation detail worth understanding

The root Application is rendered through the ArgoCD Helm chart's `extraObjects`
rather than a Terraform `kubernetes_manifest` resource. An `Application` is a
custom resource, and `kubernetes_manifest` validates against the live API at
**plan** time — which fails on a clean run, because ArgoCD's CRDs do not exist
yet. Helm installs the CRD and the object in one correctly ordered operation.

This is the same class of ordering problem that forced the Terraform split, and
it recurs constantly in Kubernetes tooling: *something must exist before
something else can be described.*

### Sync policy

Both Applications run `automated` with:

| Setting | Effect | Why it matters |
|---|---|---|
| `prune: true` | Deletes resources removed from git | Without it git is append-only: you can add things but never remove them |
| `selfHeal: true` | Reverts manual `kubectl` changes | Drift is corrected automatically instead of accumulating invisibly |

### Verified behaviour

The Deployment was deleted by hand:

```
kubectl delete deploy ci-triage-bot   →  gone
                                      →  RESTORED after ~10s, 2/2 ready
```

Nobody reapplied it. ArgoCD observed that the cluster no longer matched git and
corrected it. **Git, not the cluster, is the source of truth.**

### Sealed secrets

`k8s/sealedsecret.yaml` holds the OpenRouter key encrypted with the controller's
public key. Only the controller's private key — which never leaves the cluster —
can decrypt it, so the encrypted blob is safe in a **public** repository. The
controller unseals it into an ordinary Secret named `ci-triage-secrets`, which
`deployment.yaml` consumes without knowing anything changed.

This exists because ArgoCD can only sync what lives in git, and a raw Kubernetes
Secret must never be committed — Secrets are base64, which is *encoding, not
encryption*. Anyone with read access could run `base64 -d`.

To rotate the key, re-seal and push; ArgoCD does the rest. The plaintext is
piped through `kubeseal` and never written to disk.

### Why it matters

This is the layer that makes the system *self-correcting*. It rests on one
distinction:

> **Terraform runs when you run it. ArgoCD runs always.**

Terraform's view of the world is a snapshot taken at apply time. If someone
edits a Deployment at 2am, Terraform does not know until the next `plan`. ArgoCD
re-checks continuously, so drift has a bounded lifetime measured in minutes.

---

## 13. Stage 5 — CI

> **Question: how does a code change reach the cluster, safely, without anyone running a command?**

### The problem it removes

`ci-triage-bot:local` was a **mutable tag**. Rebuilding produced a new image
under the same name, so the Deployment spec was byte-identical and Kubernetes
correctly did nothing. The result was a silent failure mode, observed on
2026-08-29: pods served a seven-day-old image while every command exited 0 and
`kubectl rollout status` printed *"successfully rolled out"*.

Nothing was broken. Nothing reported an error. The deployment simply had not
happened.

The workaround was `kubectl rollout restart` — a step you had to *remember*,
which is exactly the kind of tribal knowledge infrastructure-as-code exists to
eliminate.

### What the pipeline does

On a push touching `backend/**`:

1. **Build** the image with buildx for `linux/amd64` and `linux/arm64`.
2. **Smoke test** it — start the container and assert `/healthz` returns 200,
   `/` returns 200, and the process runs as uid 10001. This happens *before*
   the push, so a broken image never reaches the registry.
3. **Push** to `ghcr.io/<owner>/ci-triage-bot:sha-<commit>` — an **immutable**
   tag naming the exact commit. (`:latest` is also pushed, for humans only;
   nothing deploys from it.)
4. **Bump** — rewrite `newTag` in `k8s/kustomization.yaml` and commit it as
   `chore(deploy): sha-<commit>`.

Then CI stops. ArgoCD notices the new commit and rolls it out.

### The security property

**CI holds no cluster credentials.** It can push images and write to git, and
that is all. A compromised CI pipeline cannot reach the cluster directly.

This is the structural advantage of pull-based deployment over push-based: the
cluster reaches out to git, so nothing outside needs credentials to reach in.

### The loop-breaker

The workflow triggers only on `backend/**` and the workflow file itself. This is
deliberate: the bump job commits to `k8s/`, and if that path triggered the
workflow, every build would trigger another build forever.

### Why immutable tags fix it structurally

With `sha-<commit>`, the Deployment spec genuinely changes on every deploy, so
Kubernetes has a real reason to roll. There is no `rollout restart` to remember,
and "which image is running?" is answerable by reading the tag — it names the
commit. The failure mode is not worked around; it becomes **impossible to
express**.

### Verified behaviour

Two full runs executed end to end: build → smoke test → push → tag bump →
ArgoCD sync → rolling update. The cluster now runs
`ghcr.io/williamdjting/ci-triage-bot:sha-5279906`, pulled from the registry
rather than side-loaded, with both Applications Synced and Healthy.

### Why it matters

The seven-command deploy became `git push`, and the last remaining way to be
wrong about what is running was removed.

Fittingly, this pipeline now produces exactly the kind of failure logs the
application was built to triage.

---

# Part IV — Operating it

## 14. What runs where — local vs. remote

This matters more than it first appears. **The entire runtime is local.** There
is no cloud deployment of this application.

| Component | Where it runs | Survives closing your laptop? |
|---|---|---|
| Source, manifests, Terraform | GitHub | **Yes** |
| Built images (`sha-*`) | GHCR (GitHub's registry) | **Yes** |
| CI pipeline | GitHub's runners | **Yes** |
| kind cluster (3 nodes) | Docker Desktop on your Mac | No |
| ingress-nginx | In that cluster | No |
| ArgoCD | In that cluster | No |
| sealed-secrets controller | In that cluster | No |
| **The application itself** | In that cluster | **No** |

### What happens if you shut Docker Desktop down

Everything in the cluster stops, including the app. `ci-triage.localtest.me:8080`
and `argocd.localtest.me:8080` both stop resolving to anything.

The half that lives on GitHub keeps working, but only partially usefully:

- Pushing code **still triggers CI**. The image is still built, smoke tested,
  pushed to GHCR, and the tag still gets committed to `k8s/kustomization.yaml`.
- **Nothing deploys.** ArgoCD lives in the stopped cluster, so no one is
  watching git. The commits queue up harmlessly.
- When you start Docker Desktop again, the kind containers restart on their own,
  ArgoCD wakes up, sees however many deploy commits accumulated, and syncs to
  the newest one. No manual catch-up is needed.

### Stopping vs. destroying

These are different, and the difference is easy to miss:

| Action | Effect | Cost to return |
|---|---|---|
| Quit Docker Desktop | Containers stop; they still exist on disk | Start Docker; cluster returns by itself |
| `kind delete cluster` | Containers removed; Terraform state now lies | `terraform apply` + re-seal the secret |
| `terraform destroy` (both layers) | Everything removed cleanly, state consistent | `terraform apply` + re-seal the secret |

Quitting Docker Desktop is the right way to reclaim laptop resources. Only
`terraform destroy` should be used to genuinely tear the environment down,
because it keeps Terraform's state honest.

### The one caveat when rebuilding

Sealed values are bound to the sealed-secrets controller's keypair. A destroyed
cluster generates a **new** keypair, so the committed
`k8s/sealedsecret.yaml` can no longer be decrypted and must be re-sealed. The
blob is not portable across clusters. Command in §16.

### What it would take to survive a laptop shutdown

Replace `terraform/01-cluster` with a cloud cluster module (EKS, GKE, AKS). The
image, the manifests, ArgoCD, the sealed secret, and the whole CI pipeline carry
over unchanged — which is the payoff of the layering. See §19.

---

## 15. Day-to-day operations

### Deploying a code change

```bash
# edit backend/...
git commit -am "fix: ..." && git push
```

That is the whole procedure. CI builds and publishes; ArgoCD deploys. Watch it:

```bash
gh run watch                                  # the pipeline
kubectl -n argocd get applications            # sync + health
kubectl -n ci-triage get pods -w              # the rollout
```

### Checking what is actually running

```bash
kubectl -n ci-triage get deploy ci-triage-bot \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

The tag names the commit, so this is unambiguous.

### Changing infrastructure

Cluster or platform changes go through Terraform:

```bash
cd terraform/02-platform && terraform plan   # review the diff first
terraform apply
```

Application manifest changes go through git — commit and push, ArgoCD applies
them. Never `kubectl apply` by hand: `selfHeal` will revert it, which is the
system working correctly.

### Rotating the API key

```bash
kubectl -n ci-triage create secret generic ci-triage-secrets \
  --from-env-file=.env --dry-run=client -o yaml \
  | kubeseal --format yaml \
      --controller-name sealed-secrets-controller \
      --controller-namespace kube-system \
  > k8s/sealedsecret.yaml
git commit -am "chore: rotate OpenRouter key" && git push
```

### Useful URLs

- App — <http://ci-triage.localtest.me:8080>
- ArgoCD — <http://argocd.localtest.me:8080> (user `admin`)

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

---

## 16. Building it from scratch

Requires Docker Desktop running, plus `terraform`, `kubectl`, `kind`, `kubeseal`,
and a `.env` containing `OPENROUTER_API_KEY`.

```bash
# 1. The cluster
cd terraform/01-cluster && terraform init && terraform apply

# 2. The platform
cd ../02-platform && terraform init && terraform apply

# 3. Re-seal the secret — a new cluster means a new keypair
cd ../..
kubectl -n ci-triage create secret generic ci-triage-secrets \
  --from-env-file=.env --dry-run=client -o yaml \
  | kubeseal --format yaml \
      --controller-name sealed-secrets-controller \
      --controller-namespace kube-system \
  > k8s/sealedsecret.yaml
git commit -am "chore: re-seal for new cluster" && git push
```

There is no step 4. ArgoCD deploys the application on its own, pulling the image
from GHCR.

Teardown, in reverse:

```bash
cd terraform/02-platform && terraform destroy
cd ../01-cluster        && terraform destroy
```

---

## 17. Gotchas — every one of these actually happened

**`rollout status` can report success on a stale deploy.**
Observed 2026-08-29: pods ran a seven-day-old image while every command exited 0
and `rollout status` printed "successfully rolled out". The Deployment spec never
changed, because `ci-triage-bot:local` is a mutable tag — Kubernetes compares the
*tag string*, never image contents. A green rollout is not proof you deployed
what you built. **Fixed structurally in Stage 5.**

**Terraform cannot manage resources it did not create.**
The Stage 2 cluster was made with the `kind` CLI, so it was invisible to
Terraform's state and `apply` would have failed on the name collision. Once a
resource is under Terraform, stop touching it by hand. Here it fails loudly; in
a cloud account it fails at 3am.

**A config never applied from scratch is untested.**
Rebuilding immediately exposed a bug: the kind provider writes a kubeconfig to
`terraform/01-cluster/ci-triage-config` containing `client-certificate-data` and
`client-key-data` — cluster-admin credentials in plaintext, untracked in the
repo. The `.gitignore` had been written before any apply, so it covered
`*.tfstate` but not a file only the provider creates.

**Helm silently ignores unknown values keys.**
`fullnameSelector` is not a real key in the sealed-secrets chart. No error — the
controller simply installed under its default name, which is not where
`kubeseal` looks. The correct key is `fullnameOverride`. Verify a key exists in
the chart's `values.yaml` before relying on it.

**Sealed Secrets will not adopt a Secret it did not create.**
Migrating from the imperative Stage 2 Secret produced `already exists and is not
managed by SealedSecret`. That is a safety feature. Delete the hand-made Secret —
but the controller then reported "already exists" for a Secret that was gone, and
annotating the SealedSecret did not clear the stale cache. A controller restart
forces a full reconcile; the Secret reappears in ~2s.

**Helm chart repositories move.**
The sealed-secrets chart migrated from the `bitnami-labs` org to `bitnami`, and
`bitnami-labs.github.io/sealed-secrets` now 404s. Bitnami's own catalog carries
app 0.31.0 against the current 0.39.1, so the obvious source would have silently
pinned a stale controller.

**CI runners are amd64; Apple Silicon kind nodes are arm64.**
The first GHCR push produced an amd64-only image and pods failed with `no match
for platform in manifest`. Fixed with QEMU and
`platforms: linux/amd64,linux/arm64`. Notably the app **never went down** —
`maxUnavailable: 0` kept the old pods serving while the new one failed to pull.

**`spec.selector` is immutable.**
Changing it requires deleting and recreating the Deployment — an outage in
production. Keep selector labels minimal and never touch them.

**`kind create cluster` errors if the cluster already exists,** and a kind
cluster survives a Docker Desktop restart. Guard it:
`kind get clusters | grep -q ci-triage || kind create cluster ...`

**`readOnlyRootFilesystem` blocks all writes.** Anything needing scratch space
needs an explicit volume; `/tmp` has an `emptyDir` for this.

---

## 18. Known limitations

- **Local only.** No cloud provider, no TLS, no real DNS, and nothing survives
  a laptop shutdown. See §14.
- **Terraform state is local and gitignored.** A team would need a remote
  backend (S3 + DynamoDB, GCS, Terraform Cloud) for sharing and locking.
- **`kind/cluster.yaml` is duplicated** in `terraform/01-cluster/main.tf`. The
  kind provider takes HCL, not a file path. Terraform is authoritative; the YAML
  is the manual escape hatch.
- **Sealed values are bound to one cluster's keypair** and must be re-sealed
  after a rebuild.
- **No application tests.** CI smoke tests the *image* — that it boots, serves,
  and runs as non-root — but there are no unit or integration tests for the
  triage logic itself.
- **No observability.** No metrics, no log aggregation, no alerting. Diagnosis
  is `kubectl logs`.
- **Single environment.** No staging, and no promotion path between
  environments.

---

## 19. What production would add

Roughly in order of importance:

1. **A real cluster** — replace `01-cluster` with EKS/GKE/AKS. Everything above
   it carries over unchanged.
2. **Remote Terraform state** with locking, so more than one person can operate
   it safely.
3. **TLS** — cert-manager with Let's Encrypt, and real DNS instead of
   `localtest.me`.
4. **Observability** — Prometheus and Grafana for metrics, Loki or a hosted
   service for logs, alerting on the SLOs that matter.
5. **Application tests** in CI, gating the image push the way the smoke test
   already does.
6. **Staging plus promotion** — an ArgoCD Application per environment, with
   production requiring manual sync rather than `automated`.
7. **Pod Disruption Budgets and anti-affinity**, so node maintenance cannot take
   every replica at once.
8. **Image scanning** (Trivy or Grype) in CI, and signing with cosign.
9. **NetworkPolicies** — default-deny, with egress opened only to OpenRouter.
10. **A rollback procedure.** Immutable tags make this straightforward: revert
    the deploy commit and ArgoCD rolls back on its own.

---

## 20. Summary

| Stage | Question it answers | Without it |
|---|---|---|
| 1 Docker | What is this app and what does it need? | "Works on my machine" |
| 2 Kubernetes | How does it run, stay running, and get reached? | A container that dies stays dead |
| 3 Terraform | Where does the cluster come from? | An unrepeatable hand-built cluster |
| 4 ArgoCD | How does the cluster stay in sync with git? | Silent drift, manual deploys |
| 5 CI | How does a change reach the cluster safely? | Remembered workarounds and stale images |

The result: **`git push` is the deploy.** Nobody runs `kubectl`, no CI system
holds cluster credentials, and every input except `.env` is reproducible from
this repository.
