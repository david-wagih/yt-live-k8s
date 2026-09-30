# Live Runbook — Deploy a Real Application to Kubernetes From Scratch

Your script for the stream: every step, command, and talking point, in order.
`🎙️` = something to say · `💥` = an intentional failure · `🛟` = how to recover.

---

## Pre-live checklist (do this ~1 hour before)

```bash
git pull
make preflight          # checks tools, pulls base images, builds 1.0 + 2.0, warms kind node image
make compose-down       # make sure nothing is left running
kind get clusters       # should NOT list devops-live yet (we create it live)
docker image rm devops-live-api:1.0 devops-live-api:2.0   # optional: so Part 1 builds it live
```

- [ ] Terminal font big, light/dark theme readable on stream
- [ ] Two terminal tabs: **main** + **watch** (`kubectl get pods -w`)
- [ ] Editor open on the repo with `k8s/` (empty) and `final/k8s/` (reference)
- [ ] Nothing on `:8000` and `:8080` (`lsof -i :8000 -i :8080`)
- [ ] This runbook open on a second screen

**Timing (≈2 hours, don't obsess over it):**

```text
00:00–00:10  Intro + architecture
00:10–00:20  Part 1  Run it with Docker Compose
00:20–00:35  Part 2  Create the Kind cluster
00:35–00:55  Part 3  Deployment (+ ImagePullBackOff + CrashLoopBackOff)
00:55–01:15  Part 4–5  ConfigMap, Secret, PostgreSQL
01:15–01:20  Part 6  Service + port-forward  → first milestone 🎉
01:20–01:35  Part 7–8  Health checks + resources
01:35–01:50  Part 9–10  Scaling, self-healing, rolling update, rollback
01:50–02:00+ Part 11 Troubleshooting challenge + Part 12 "what changes in production" + Q&A
```

---

## Intro (00:00)

🎙️ "By the end of this live, we'll take a real application that currently runs locally,
containerize it, deploy it to Kubernetes, expose it, configure it, scale it, and troubleshoot it."

🎙️ "We are not here to build the application. Imagine your development team already gave
you this application. Our job is to deploy and operate it."

Show the architecture from the README and walk through `app/main.py` briefly:
- endpoints `/tasks`, `/health`, `/ready`
- **all config comes from environment variables** — remember this, it matters in Part 3
- open `app/Dockerfile` — base image, deps, non-root user, `CMD`

---

## Part 1 — Run it normally (Docker Compose)

```bash
docker compose up --build
```

In a second tab:

```bash
curl localhost:8000/
curl -X POST localhost:8000/tasks -H 'Content-Type: application/json' -d '{"title":"Learn Kubernetes"}'
curl localhost:8000/tasks
```

🎙️ "Docker Compose works perfectly on my laptop. But what happens when we need orchestration,
scaling, self-healing, rolling updates, and production-grade operations? That's where Kubernetes comes in."

```bash
docker compose down -v
docker images | grep devops-live-api     # compose built + tagged devops-live-api:1.0 — remember this
```

---

## Part 2 — Create the Kubernetes cluster

```bash
docker version && kubectl version --client && kind version

kind create cluster --name devops-live --config kind-config.yaml
kubectl get nodes -o wide
docker ps                        # 🎙️ "each Kubernetes node is… a Docker container"
```

Explain:

```text
Docker
├── devops-live-control-plane   (container)
│   └── API Server, Scheduler, Controller Manager, etcd, kubelet
├── devops-live-worker          (container) → kubelet + our Pods
└── devops-live-worker2         (container) → kubelet + our Pods
```

```bash
kubectl get pods -n kube-system       # callback to the architecture episode
```

Create our own namespace and make it the default (so we don't type `-n` all day):

```bash
kubectl create namespace devops-live
kubectl config set-context --current --namespace=devops-live
```

> Using the plain `kind create cluster --name devops-live` (single node) also works for everything below.

---

## Part 3 — Deploy the application

Start the **watch** tab now and leave it visible:

```bash
kubectl get pods -w
```

Create `k8s/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
        - name: backend
          image: devops-live-api:1.0
          ports:
            - containerPort: 8000
```

🎙️ Walk through it: `replicas`, `selector` ↔ `template.metadata.labels` (they must match), the Pod template.

```bash
kubectl apply -f k8s/deployment.yaml
kubectl get deploy,rs,pods
```

### 💥 Failure #1 — `ImagePullBackOff`

🎙️ "Why can't Kubernetes find our image? It's right there in `docker images`!"

```bash
kubectl describe pod <pod-name>     # scroll to Events: "pull access denied ... docker.io/library/devops-live-api"
```

🎙️ The image exists in **my laptop's Docker daemon**, not inside the Kind nodes.
The kubelet (via containerd *inside the node container*) tries Docker Hub and fails.

```bash
kind load docker-image devops-live-api:1.0 --name devops-live
kubectl rollout restart deployment backend
```

### 💥 Failure #2 — `CrashLoopBackOff`

Pods now start… and crash. Repeatedly.

```bash
kubectl get pods                   # RESTARTS going up, STATUS CrashLoopBackOff
kubectl logs <pod-name>            # FATAL: missing required environment variables: DB_HOST, DB_USER, DB_PASSWORD
kubectl logs <pod-name> --previous # logs of the previous (crashed) container
```

🎙️ "Kubernetes did its job — it pulled the image and started the container. The *application*
refuses to start without configuration. In Compose we had `environment:`. In Kubernetes we
use ConfigMaps and Secrets."

---

## Part 4 — ConfigMaps and Secrets

`k8s/configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: backend-config
data:
  DB_HOST: postgres
  DB_PORT: "5432"
  DB_NAME: tasks
```

`k8s/secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: backend-secret
type: Opaque
stringData:
  DB_USER: devops
  DB_PASSWORD: supersecret
```

Add to the container in `k8s/deployment.yaml` (under `ports:`):

```yaml
          envFrom:
            - configMapRef:
                name: backend-config
            - secretRef:
                name: backend-secret
```

```bash
kubectl apply -f k8s/configmap.yaml -f k8s/secret.yaml -f k8s/deployment.yaml
kubectl get pods
kubectl get secret backend-secret -o yaml                                      # base64…
kubectl get secret backend-secret -o jsonpath='{.data.DB_PASSWORD}' | base64 -d; echo
```

🎙️ "Secrets are **base64-encoded, not encrypted**. Anyone who can read the Secret can read the password.
Never commit real secrets to git." (callback to the ConfigMaps & Secrets episode)

Pods are `Running` now 🎉 … but:

```bash
kubectl logs deploy/backend        # WARNING cannot reach database postgres:5432 ... Name or service not known
```

🎙️ "Running doesn't mean working. We told it `DB_HOST: postgres` — but there is no postgres yet."

---

## Part 5 — Deploy PostgreSQL

Copy them from the reference (they're longer, walk through them instead of typing):

```bash
cp final/k8s/03-postgres-deployment.yaml k8s/postgres-deployment.yaml
cp final/k8s/04-postgres-service.yaml    k8s/postgres-service.yaml
```

Talking points while reading the YAML:
- `secretKeyRef` / `configMapKeyRef` — reuse the **same** Secret/ConfigMap, key by key
- `readinessProbe` with `pg_isready`
- `emptyDir` volume → **data is lost when the Pod dies** (we'll prove it in Part 9)
- The **Service name `postgres`** becomes a DNS name → that's why `DB_HOST: postgres` works

🎙️ "This is fine for our learning environment, but this is not how I'd deploy a production database.
Databases need stable identity and persistent storage — that's what **StatefulSets** and
PersistentVolumes are for. We'll cover StatefulSets in a separate episode."

> Namespace note: files in `final/k8s/` include `namespace: devops-live`; files you type in `k8s/`
> don't need it because we set the default namespace in Part 2.

```bash
kubectl apply -f k8s/postgres-deployment.yaml -f k8s/postgres-service.yaml
kubectl get pods
kubectl logs deploy/backend        # errors stop once postgres is ready
```

---

## Part 6 — Expose the application (Service)

`k8s/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
spec:
  selector:
    app: backend
  ports:
    - port: 80
      targetPort: 8000
```

```bash
kubectl apply -f k8s/service.yaml
kubectl get svc
kubectl get endpoints backend       # 🎙️ the Pod IPs the Service routes to
kubectl get pods -o wide            # same IPs!
```

```text
Service (stable name + IP)
   |
   +---- Pod  10.244.1.5
   |
   +---- Pod  10.244.2.7
```

🎙️ "The Service does not care which Pod handles the request. Pods come and go; the Service stays."

```bash
kubectl port-forward service/backend 8080:80
```

Second tab:

```bash
curl localhost:8080/
curl -X POST localhost:8080/tasks -H 'Content-Type: application/json' -d '{"title":"Deployed on Kubernetes!"}'
curl localhost:8080/tasks
```

🎉 **First major milestone.**

Show the load balancing from *inside* the cluster (port-forward pins one Pod, so it can't show this):

```bash
make lb-demo
# = kubectl exec deploy/backend -- python -c "... call http://backend/ 10 times ..."
```

Different `"pod"` values → the Service is spreading requests.

> 🛟 **Lost?** `kubectl apply -f final/k8s/` brings everything to the known-good state.

---

## Part 7 — Health checks

Add to the container in `k8s/deployment.yaml`:

```yaml
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: 8000
            initialDelaySeconds: 2
            periodSeconds: 5
```

```text
Readiness  → Should Kubernetes SEND TRAFFIC here?      (/ready checks the DB)
Liveness   → Should Kubernetes RESTART this container?  (/health never checks the DB)
```

🎙️ Why doesn't liveness check the DB? If the DB goes down and liveness depends on it,
Kubernetes restarts **every** backend Pod in a loop — and it fixes nothing.

```bash
kubectl apply -f k8s/deployment.yaml
kubectl get pods -w
```

### 💥 Break liveness on purpose — the "wow" moment

```bash
kubectl get pods
kubectl exec <pod-name> -- python break_health.py
kubectl get pods -w         # after ~30s (3 failures × 10s) RESTARTS goes 0 → 1
kubectl describe pod <pod-name>   # Events: "Liveness probe failed: HTTP probe failed with statuscode: 500"
                                  #         "Container backend failed liveness probe, will be restarted"
```

🎙️ "Nobody got paged. Kubernetes noticed, restarted it, and the Pod is healthy again."

### 💥 Readiness in action (optional)

```bash
kubectl scale deployment postgres --replicas=0
kubectl get pods -w              # backend Pods go 1/1 → 0/1 (NOT restarted!)
kubectl get endpoints backend    # empty → no traffic sent to broken Pods
kubectl scale deployment postgres --replicas=1
```

---

## Part 8 — Resources

Add to the container in `k8s/deployment.yaml`:

```yaml
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
```

```text
Requests → used for SCHEDULING ("I need at least this much")
Limits   → the MAXIMUM allowed usage
           CPU over limit    → throttled
           Memory over limit → OOMKilled
```

```bash
kubectl apply -f k8s/deployment.yaml
kubectl describe node devops-live-worker | grep -A 8 "Allocated resources"
```

🎙️ Keep it short — resource management deserves its own episode. (Troubleshooting has an OOMKilled + Pending scenario.)

---

## Part 9 — Scaling & self-healing

```bash
kubectl scale deployment backend --replicas=5
kubectl get pods -o wide            # 🎙️ spread across both worker nodes
kubectl get endpoints backend       # 5 IPs now
```

Delete a Pod and watch it come back:

```bash
kubectl delete pod <pod-name>
kubectl get pods -w
```

🎙️ "This is why we deploy **Deployments**, not individual Pods. The ReplicaSet wants 5, sees 4, creates 1."

Optional — prove the `emptyDir` warning from Part 5:

```bash
curl localhost:8080/tasks                 # tasks exist (restart port-forward if it died)
kubectl delete pod -l app=postgres
curl localhost:8080/tasks                 # [] — data gone. That's why databases need persistent storage.
```

Scale back:

```bash
kubectl scale deployment backend --replicas=3
```

> Note: `kubectl scale` is imperative — the next `kubectl apply` resets replicas to what's in the file.
> 🎙️ This is exactly the drift that GitOps solves.

---

## Part 10 — Rolling update & rollback

```bash
docker build -t devops-live-api:2.0 --build-arg APP_VERSION=2.0 app     # or: make build-v2
kind load docker-image devops-live-api:2.0 --name devops-live
```

In the watch tab, start continuous traffic from a **separate** Pod so we SEE versions switch:

```bash
make traffic
# = kubectl run traffic --rm -it --restart=Never --image=devops-live-api:1.0 -- python traffic.py
```

It prints `version=1.0 pod=backend-xxxx` lines… watch them turn into `version=2.0 pod=backend-yyyy`, with no `ERROR`s. Ctrl+C to stop.

Main tab:

```bash
kubectl set image deployment/backend backend=devops-live-api:2.0
kubectl rollout status deployment/backend
kubectl get pods
kubectl rollout history deployment/backend
```

🎙️ Zero downtime: new Pods must pass readiness before old ones are removed
(`final/k8s/05-backend-deployment.yaml` sets `maxUnavailable: 0`, `maxSurge: 1`).

Rollback:

```bash
kubectl rollout undo deployment/backend
kubectl rollout status deployment/backend
curl localhost:8080/          # "version": "1.0"
```

```text
Deploy → Scale → Update → Rollback
```

---

## Part 11 — Troubleshooting challenge (15–20 min)

See [`troubleshooting/README.md`](../troubleshooting/README.md). Reset to known-good first:

```bash
kubectl apply -f final/k8s/
```

Then apply a broken file, **let chat diagnose it**, and fix it. The debugging toolbox:

```bash
kubectl get pods                     # STATUS + RESTARTS + READY
kubectl describe pod <pod>           # Events at the bottom!
kubectl logs <pod> [--previous]      # what the app says
kubectl get endpoints <svc>          # does the Service have targets?
kubectl get events --sort-by=.lastTimestamp
kubectl exec -it <pod> -- sh         # look around inside
```

🎙️ "Tutorials where everything magically works don't teach you much. This is how engineers
actually debug Kubernetes."

---

## Part 12 — What changes in production?

Show the final architecture (README) and then:

```text
Local Kind cluster      →  Managed Kubernetes (EKS / GKE / AKS)
kubectl port-forward    →  Ingress / Gateway API / LoadBalancer
kind load docker-image  →  Container registry (ECR / GAR / ACR / GHCR) + imagePullSecrets
Plain Secrets in git    →  External Secrets / Vault / Sealed Secrets
emptyDir                →  PersistentVolumes / StatefulSets / Managed databases (RDS, Cloud SQL)
kubectl apply           →  CI/CD + GitOps (Argo CD / Flux)
kubectl scale           →  HorizontalPodAutoscaler
Raw YAML                →  Helm / Kustomize
```

🎙️ "We learned the Kubernetes **primitives** today. Production adds layers on top — but every one
of those layers is still creating Deployments, Services, ConfigMaps and Secrets underneath."

Tease next lives: **Helm chart from these manifests**, **StatefulSets**, **Ingress**, **Argo CD**.

---

## Cleanup

```bash
kubectl delete namespace devops-live     # or: make reset
kind delete cluster --name devops-live   # or: make cluster-delete
```

## 🛟 Emergency buttons

| Problem                               | Fix                                                                 |
|---------------------------------------|---------------------------------------------------------------------|
| YAML typo, lost the flow              | `kubectl apply -f final/k8s/`                                       |
| Everything is a mess                  | `make reset && make deploy-final`                                   |
| `ImagePullBackOff` on postgres        | Docker Hub rate limit → `docker pull postgres:16-alpine && make load-postgres` |
| `ImagePullBackOff` on backend         | `make load` (or `make load-v2`) — image isn't inside the Kind nodes |
| port-forward died                     | It dies when its Pod is deleted/replaced — just rerun it            |
| `curl: connection refused` on 8080    | port-forward not running                                            |
| Cluster totally broken                | `make cluster-delete && make cluster && make load ns deploy-final`  |
