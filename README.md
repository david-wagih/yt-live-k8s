# Deploy a Real Application to Kubernetes From Scratch

**YouTube Live — Local Kubernetes with Kind**

> "By the end of this live, we'll take a real application that currently runs locally,
> containerize it, deploy it to Kubernetes, expose it, configure it, scale it, and troubleshoot it."

We are **not** here to build the application. Imagine the development team already
handed us this app. Our job is to **deploy and operate it**.

## The application

A small **Task Management API** (Python / FastAPI) backed by **PostgreSQL**.

| Method | Path                  | What it does                                             |
|--------|-----------------------|----------------------------------------------------------|
| GET    | `/`                   | App info: version + **which pod answered**               |
| GET    | `/tasks`              | List tasks                                               |
| POST   | `/tasks`              | Create a task — `{"title": "..."}`                       |
| GET    | `/health`             | **Liveness** — is the process alive? (never touches DB)  |
| GET    | `/ready`              | **Readiness** — is the DB reachable? Can I take traffic? |
| POST   | `/admin/break-health` | Demo helper — makes `/health` return 500                 |

Configuration comes **only** from environment variables:
`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`.
If `DB_HOST`, `DB_USER` or `DB_PASSWORD` is missing, the app exits on purpose
(→ `CrashLoopBackOff` in Kubernetes).

## Architecture

```text
                    localhost:8080
                          |
                  (kubectl port-forward)
                          |
                          v
                  Service: backend
                          |
                +---------+---------+
                |                   |
                v                   v
          Backend Pod          Backend Pod
                \                   /
                 +-------+---------+
                         |
                         v
                  Service: postgres
                         |
                         v
                    PostgreSQL Pod
```

## Repo layout

```text
.
├── app/                     # The application "the dev team gave us"
│   ├── main.py
│   ├── break_health.py      # helper: kubectl exec <pod> -- python break_health.py
│   ├── traffic.py           # helper: continuous requests to the Service (rolling update demo)
│   ├── requirements.txt
│   └── Dockerfile
├── docker-compose.yml       # Part 1: "it works on my laptop"
├── kind-config.yaml         # 1 control-plane + 2 workers
├── k8s/                     # EMPTY WORKSPACE — we write the manifests here, live
├── final/k8s/               # Known-good reference manifests (recovery point!)
├── final/observability/     # 🆕 Bonus: Jaeger + ConfigMap that turns on FastAPI's native OpenTelemetry
├── troubleshooting/         # Intentionally broken manifests for the debugging challenge
├── docs/RUNBOOK.md          # The live script: every step, command, and talking point
└── Makefile                 # Shortcuts (make help)
```

## Prerequisites

- Docker (Docker Desktop / Engine)
- [`kubectl`](https://kubernetes.io/docs/tasks/tools/)
- [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- `make` and `curl` (optional but handy)

## Quick start (the whole thing in 6 commands)

```bash
make build                 # docker build -> devops-live-api:1.0
make cluster               # kind create cluster --name devops-live
make load                  # kind load docker-image devops-live-api:1.0
make deploy-final          # kubectl apply -f final/k8s/
make port-forward          # localhost:8080 -> service/backend
curl localhost:8080/tasks
```

Run `make help` for everything else.

## Before going live ✅

See the **Pre-live checklist** at the top of [`docs/RUNBOOK.md`](docs/RUNBOOK.md).
The short version: run `make preflight` an hour before, so all images are already
pulled (Docker Hub rate limits during a live stream are not fun).

## 🆕 Bonus: FastAPI native OpenTelemetry

FastAPI 0.142 (Sept 2026) records traces, metrics and logs **by default**. This app uses it, and
tracing turns on through the **ConfigMap alone**, with no code changes:

```bash
make observability     # deploy Jaeger + ConfigMap with OTEL_* keys + rollout restart
make jaeger-ui         # http://localhost:16686 → service "task-api"
```

See the Bonus section in [`docs/RUNBOOK.md`](docs/RUNBOOK.md).

## Out of scope today (future lives)

- **Helm** — raw manifests make the concepts clearer. Next: *"Turn Our Kubernetes Manifests Into a Helm Chart."*
- **StatefulSets** — databases need stable identity + storage; separate episode.
- **Ingress / Gateway API**, **HPA**, **GitOps with Argo CD**.
