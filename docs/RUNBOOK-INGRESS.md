# Live Runbook — From Pods to the Browser: Services, Probes and Ingress

Your script for the stream: every step, command, and talking point, in order.
`🎙️` = something to say · `💥` = an intentional failure · `🛟` = how to recover.

Manifests live in `k8s/`:

```text
k8s/
├── cluster.yaml          # kind cluster: 1 control-plane (Ingress-ready) + 2 workers
├── db/
│   ├── deployment.yaml   # devops-live-db  (postgres:16-alpine)
│   └── service.yaml      # devops-live-db:5432
└── api/
    ├── deployment.yaml   # devops-live-api (2 replicas + readinessProbe)
    ├── service.yaml      # devops-live-api:8000
    └── ingress.yaml      # api.localhost → devops-live-api:8000
```

---

## Pre-live checklist (do this ~1 hour before)

```bash
git pull
make preflight              # checks tools, pulls base images, builds 1.0 + 2.0, warms kind node image
make compose-down           # make sure nothing is left running
make cluster-delete         # start clean (ignore "not found")
```

Optional — if your network is slow, pre-create everything that downloads from the internet:

```bash
make cluster load load-v2 load-postgres
make ingress-controller     # pulls ingress-nginx from registry.k8s.io (~30s)
```

Then open `http://api.localhost:8081` in the stream browser → you should see nginx's **404**
(the controller answers, there's just no Ingress yet). ✅

- [ ] Terminal font big, theme readable on stream
- [ ] Two terminal tabs: **main** + **watch** (`kubectl get pods -w`)
- [ ] Editor open on `k8s/`
- [ ] **Chrome or Firefox** for the demo (they resolve `*.localhost` to 127.0.0.1 out of the box)
- [ ] Nothing on `:8000`, `:8080`, `:8081`, `:8443` (`lsof -i :8000 -i :8080 -i :8081 -i :8443`)
- [ ] This runbook open on a second screen

**Timing (≈90 min, don't obsess over it):**

```text
00:00–00:05  Intro + architecture
00:05–00:15  Part 1  Run it with Compose
00:15–00:25  Part 2  Create the kind cluster (Ingress-ready)
00:25–00:40  Part 3  Deploy PostgreSQL (Deployment + Service)
00:40–00:55  Part 4  Deploy the API + port-forward       → first milestone 🎉
00:55–01:05  Part 5  Readiness probe
01:05–01:20  Part 6  Ingress: open the API in the browser → second milestone 🎉
01:20–01:25  Part 7  Ingress × readiness: the 503 moment
01:25–01:35  Part 8  Scale + rolling update, seen from the browser
01:35–01:45+ Part 9  port-forward vs Service vs Ingress vs Gateway API + Q&A
```

---

## Intro (00:00)

🎙️ "Today we take an API, deploy it to Kubernetes, and end with opening it in the **browser**
like a real user would — no `port-forward`, no tricks."

```text
browser ──► Ingress (nginx) ──► Service devops-live-api ──► API Pods ──► Service devops-live-db ──► Postgres Pod
```

Walk through `app/main.py` briefly:
- endpoints `/`, `/tasks`, `/health`, `/ready`
- `/ready` runs `SELECT 1` against Postgres — remember it, it matters in Part 5
- config comes from env vars: `DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_NAME` (default `tasks`)

---

## Part 1 — Run it normally (Compose)

```bash
make compose-up
curl localhost:8000/
curl -X POST localhost:8000/tasks -H 'Content-Type: application/json' -d '{"title":"hello"}'
curl localhost:8000/tasks
make compose-down
```

🎙️ "Works on my machine. Now let's make it work on a cluster."

---

## Part 2 — Create the cluster

Open `k8s/cluster.yaml`:

```yaml
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 8081
      - containerPort: 443
        hostPort: 8443
  - role: worker
  - role: worker
```

🎙️ "Two things here we'll only need at the end — I'm planting them now:
the `ingress-ready` label, and the port mappings: my laptop's 8081 goes to port 80 of this node.
That's where our Ingress controller will listen."

🎙️ "Why 8081 and not 80? Rootless Podman can't bind ports below 1024."

```bash
make cluster                # kind create cluster --name devops-live --config kind-config.yaml
make ns                     # namespace devops-live + make it the default
kubectl get nodes --show-labels | grep ingress-ready
make load load-postgres     # put our images inside the kind nodes
```

---

## Part 3 — Deploy PostgreSQL

`k8s/db/deployment.yaml` — highlight the env:

```yaml
        env:
        - name: POSTGRES_USER
          value: "postgres"
        - name: POSTGRES_PASSWORD
          value: "password"
        - name: POSTGRES_DB # the API connects to DB_NAME (default "tasks")
          value: "tasks"
```

🎙️ "The API connects to a database called `tasks`. Forget `POSTGRES_DB` and Postgres only
creates `postgres` — the API would start fine and then fail on every request."

`k8s/db/service.yaml` → `devops-live-db:5432`, type `ClusterIP`.

```bash
kubectl apply -f k8s/db/
kubectl get deploy,pods,svc
```

🎙️ "The Service name **is** the DNS name. The API will find the database at `devops-live-db`."

---

## Part 4 — Deploy the API

Start `k8s/api/deployment.yaml` **without** the `readinessProbe` block (we add it in Part 5):

```yaml
spec:
  replicas: 2
  ...
      containers:
      - name: devops-live-api
        image: docker.io/library/devops-live-api:1.0
        ports:
        - containerPort: 8000
        env:
        - name: DB_HOST
          value: "devops-live-db"   # ← the Service name from Part 3
        - name: DB_USER
          value: "postgres"
        - name: DB_PASSWORD
          value: "password"
```

```bash
kubectl apply -f k8s/api/deployment.yaml -f k8s/api/service.yaml
kubectl get pods -o wide                     # 🎙️ spread across the 2 workers
kubectl get endpointslices -l kubernetes.io/service-name=devops-live-api   # same Pod IPs
```

The "old way" to reach it:

```bash
kubectl port-forward service/devops-live-api 8000:8000
# other tab:
curl localhost:8000/
curl -X POST localhost:8000/tasks -H 'Content-Type: application/json' -d '{"title":"from k8s"}'
curl localhost:8000/tasks
```

🎉 **First milestone.** 🎙️ "It works… but this is a tunnel from *my laptop*. Close the terminal,
it's gone. Nobody else can use it. Keep that in mind."

Stop the port-forward (`Ctrl+C`).

---

## Part 5 — Readiness probe

🎙️ "Right now Kubernetes thinks a Pod is ready the moment the process starts. Let's prove that's a lie."

💥 Kill the database **without** a probe:

```bash
kubectl scale deploy/devops-live-db --replicas=0
kubectl get pods            # API pods still 1/1 Ready… but every /tasks call would fail
```

Add to `k8s/api/deployment.yaml` (under the container):

```yaml
        # Readiness -> "should Kubernetes SEND TRAFFIC to this Pod?"
        # /ready checks the DB; not ready = removed from the Service endpoints (and the Ingress)
        readinessProbe:
          httpGet:
            path: /ready
            port: 8000
          initialDelaySeconds: 2
          periodSeconds: 5
```

```bash
kubectl apply -f k8s/api/deployment.yaml
kubectl get pods -w          # new pods come up 0/1 — DB is still down!
```

🎙️ "Running, but 0/1. Kubernetes isn't restarting them — it just won't send them traffic."

```bash
kubectl get endpointslices -l kubernetes.io/service-name=devops-live-api -o yaml | grep -A2 conditions
kubectl scale deploy/devops-live-db --replicas=1
kubectl get pods -w          # back to 1/1 on their own
```

🎙️ "Note: the DB Pod was replaced, so its data is gone — it uses `emptyDir`. That's a topic for
PersistentVolumes / StatefulSets."

---

## Part 6 — Ingress: open the API in the browser

🎙️ "An Ingress is just **rules**: 'this hostname/path goes to that Service'. Something has to
read those rules and actually proxy the traffic — that's the **Ingress controller**. Kubernetes
doesn't ship one."

### 1. Install the controller

```bash
make ingress-controller
kubectl -n ingress-nginx get pods -o wide    # 🎙️ on devops-live-control-plane!
```

🎙️ "We pin it to the control-plane because that's the node whose port 80 is wired to my
laptop's 8081 — remember the label from Part 2? That's why it's there."

🎙️ "Honesty moment: ingress-nginx was retired in March 2026. It's still the clearest way to
learn Ingress, and it's everywhere in existing clusters. The future is the **Gateway API** — next live."

Open `http://localhost:8081` in the browser → nginx **404**.
🎙️ "nginx answers — but it has no rules yet."

### 2. Write the Ingress

`k8s/api/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: devops-live-api
spec:
  ingressClassName: nginx # handled by the ingress-nginx controller
  rules:
  - host: api.localhost # *.localhost resolves to 127.0.0.1, no /etc/hosts needed
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: devops-live-api
            port:
              number: 8000
```

```bash
kubectl apply -f k8s/api/ingress.yaml
kubectl get ingress
kubectl describe ingress devops-live-api     # 🎙️ backends = the Pod IPs
```

### 3. Open it 🎉

- `http://api.localhost:8081/` → refresh a few times: the `pod` field changes
- `http://api.localhost:8081/tasks`
- `http://api.localhost:8081/docs` → create a task from Swagger UI, then refresh `/tasks`
- `http://localhost:8081/` → still **404**

🎙️ "Same port, same nginx — different hostname, different answer. Routing is by **Host header**."

```bash
curl -H 'Host: api.localhost' http://localhost:8081/    # proves it: the Host header is the key
```

🎉 **Second milestone.** No port-forward running.

---

## Part 7 — Ingress × readiness: the 503 moment 💥

Split screen: **watch** tab with `kubectl get pods -w` + browser on `http://api.localhost:8081/`.

```bash
kubectl scale deploy/devops-live-db --replicas=0
```

Keep refreshing → after a few seconds: **503 Service Temporarily Unavailable** (nginx).

🎙️ "The readiness probe from Part 5 is what tells nginx 'no healthy backends'. Users get a
clean 503 instead of a hanging request or a stack trace."

⚠️ nginx lags a few seconds behind the probe — if you still see 200, refresh again.

```bash
kubectl scale deploy/devops-live-db --replicas=1
```

Refresh → 200 again, nobody touched the API Pods.

---

## Part 8 — Scale + rolling update, seen from the browser

```bash
kubectl scale deploy/devops-live-api --replicas=4
kubectl get pods -o wide
```

Refresh `/` → up to 4 different `pod` names.

Rolling update to 2.0 (image already loaded with `make load-v2`; run it now if not).
Optional: in the **watch** tab run `make traffic` (a Pod calling the Service every 0.5s) to see
`version=1.0` turn into `version=2.0` with zero errors.

```bash
kubectl set image deploy/devops-live-api devops-live-api=docker.io/library/devops-live-api:2.0
kubectl rollout status deploy/devops-live-api
```

Refresh `/` during the rollout → `version` flips from `1.0` to `2.0`.

```bash
kubectl rollout undo deploy/devops-live-api    # 🛟 rollback
```

kubectl prints a warning that `rollout undo` doesn't update the `last-applied-configuration`.
🎙️ "Imperative commands drift from the YAML in git. In real life you'd change the image in
the file and `kubectl apply`. GitOps tools like Argo CD exist for exactly this."

🎙️ "Readiness matters here too: a new Pod gets traffic from the Ingress only once it's ready."

---

## Part 9 — Wrap-up: how do we reach an app in Kubernetes?

```text
kubectl port-forward  → a dev tunnel from my laptop to one Pod. Dies with the terminal.
Service (ClusterIP)   → stable name + IP, load-balances — but only INSIDE the cluster.
Service (LoadBalancer)→ one cloud load balancer per Service. Expensive at scale.
Ingress               → one entry point, L7 routing by host/path to many Services.
Gateway API           → the successor: richer routing, role separation, many implementations.
```

🎙️ "In the cloud, the controller gets a real load balancer and you'd point DNS at it:
`https://api.yourcompany.com` instead of `api.localhost:8081`. Same Ingress YAML."

Tease next lives: **Gateway API**, **TLS with cert-manager**, **Helm chart from these manifests**,
**StatefulSets + PersistentVolumes**.

---

## Cleanup

```bash
make reset               # delete namespace devops-live (the controller stays)
make cluster-delete      # delete the whole kind cluster
```

## 🛟 Emergency buttons

| Problem                                         | Fix                                                                                   |
|-------------------------------------------------|---------------------------------------------------------------------------------------|
| YAML typo, lost the flow                        | `git checkout k8s/ && make deploy`                                                    |
| `ImagePullBackOff` on devops-live-api           | `make load` (or `make load-v2`) — image isn't inside the kind nodes                   |
| `ImagePullBackOff` on postgres                  | `docker pull postgres:16-alpine && make load-postgres`                                |
| API pods stuck `0/1`                            | DB down or wrong name → `kubectl get pods`, check `DB_HOST` = `devops-live-db`        |
| `/tasks` → 500, `database "tasks" does not exist` | `POSTGRES_DB: tasks` missing → add it, `kubectl delete pod -l app=devops-live-db`   |
| Browser: connection refused on `:8081`          | Controller not on the control-plane → `kubectl -n ingress-nginx get pods -o wide`, rerun `make ingress-controller` |
| Browser: 404 from nginx                         | Wrong host (use `api.localhost`) or `ingressClassName` missing                         |
| Browser: 503 from nginx                         | No ready pods → `kubectl get pods`, `kubectl get endpointslices`                       |
| `api.localhost` doesn't resolve (Safari)        | Use Chrome/Firefox, or add `127.0.0.1 api.localhost` to `/etc/hosts`                   |
| `kubectl apply ingress.yaml` → webhook error    | Controller still starting → wait for `make ingress-controller` to finish, retry       |
| Cluster totally broken                          | `make cluster-delete && make cluster ns load load-v2 load-postgres ingress-controller deploy` |
