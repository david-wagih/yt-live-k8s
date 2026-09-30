# Troubleshooting Challenge

Each file here is a **broken** version of a known-good manifest from `final/k8s/`.
Apply one, let the audience diagnose it, then fix it.

**Start from a known-good state:**

```bash
kubectl apply -f final/k8s/
kubectl -n devops-live get pods      # everything Running and READY
```

**The toolbox:**

```bash
kubectl get pods                          # STATUS, READY, RESTARTS
kubectl describe pod <pod>                # read the Events at the bottom
kubectl logs <pod> [--previous]           # what did the app say?
kubectl get endpoints <service>           # does the Service have any targets?
kubectl get events --sort-by=.lastTimestamp
```

**Fix for every scenario:** re-apply the known-good file(s):

```bash
kubectl apply -f final/k8s/
```

| # | Break it with                                        | What the audience sees                 |
|---|------------------------------------------------------|----------------------------------------|
| 1 | `kubectl apply -f troubleshooting/01-wrong-image.yaml`    | New Pods never start                  |
| 2 | `kubectl apply -f troubleshooting/02-crashloop.yaml`      | Pods keep restarting                  |
| 3 | `kubectl apply -f troubleshooting/03-wrong-selector.yaml` | Pods look fine, but requests fail     |
| 4 | `kubectl apply -f troubleshooting/04-wrong-db-host.yaml` then `kubectl -n devops-live rollout restart deployment/backend` | Pods Running but `0/1` READY |
| 5 | `kubectl apply -f troubleshooting/05-oomkilled.yaml` *(bonus)* | Pods keep restarting           |
| 6 | `kubectl apply -f troubleshooting/06-pending.yaml` *(bonus)*   | New Pod stuck forever          |

> Note: thanks to `maxUnavailable: 0`, the **old** healthy Pods keep running while the new
> broken ones fail — a great moment to point out that rolling updates protected us.
> For scenario 3 the Deployment is untouched; only the Service is broken.

---

Answers below — don't scroll on stream 😉

<details>
<summary><b>1 — Wrong image tag → <code>ErrImagePull</code> / <code>ImagePullBackOff</code></b></summary>

- `kubectl get pods` → `ErrImagePull` / `ImagePullBackOff`
- `kubectl describe pod <pod>` → Events: `Failed to pull image "devops-live-api:1.0.1" ... not found`
- Cause: the tag `1.0.1` doesn't exist (we only built/loaded `1.0` and `2.0`).
- Fix: correct the tag → `kubectl apply -f final/k8s/05-backend-deployment.yaml`
- Also useful: `kubectl rollout undo deployment/backend`
</details>

<details>
<summary><b>2 — Secret not referenced → <code>CrashLoopBackOff</code></b></summary>

- `kubectl get pods` → `CrashLoopBackOff`, RESTARTS increasing
- `kubectl logs <pod>` (or `--previous`) → `FATAL: missing required environment variables: DB_USER, DB_PASSWORD`
- Cause: the `secretRef: backend-secret` was removed from `envFrom`.
- Fix: `kubectl apply -f final/k8s/05-backend-deployment.yaml`
- Lesson: `describe` tells you **Kubernetes'** side of the story; `logs` tells you the **app's** side.
</details>

<details>
<summary><b>3 — Wrong Service selector → no endpoints</b></summary>

- `kubectl get pods` → all Running, all Ready. Looks perfect!
- `kubectl port-forward service/backend 8080:80` → error: `no matching pods found` (or requests fail)
- `kubectl get endpoints backend` → `<none>`
- `kubectl describe svc backend` → `Selector: app=back-end`, while Pods are labelled `app=backend`
  (`kubectl get pods --show-labels`)
- Fix: `kubectl apply -f final/k8s/06-backend-service.yaml`
- Lesson: Services find Pods **only** through labels.
</details>

<details>
<summary><b>4 — Wrong DB hostname → Running but not Ready</b></summary>

- `kubectl get pods` → `Running` but `0/1` READY (after the rollout restart)
- `kubectl describe pod <pod>` → `Readiness probe failed: HTTP probe failed with statuscode: 503`
- `kubectl logs <pod>` → `cannot reach database postgresql:5432 ... Name or service not known`
- `kubectl get svc` → the Service is called `postgres`, not `postgresql`
- Fix: `kubectl apply -f final/k8s/01-configmap.yaml` **and** `kubectl rollout restart deployment/backend`
- Lessons:
  - Changing a ConfigMap does **not** restart Pods — env vars are read only at container start.
  - Readiness kept these Pods out of the Service: the old ones kept serving (thanks to `maxUnavailable: 0`)
    and the liveness probe did NOT restart them (liveness doesn't depend on the DB — by design).
</details>

<details>
<summary><b>5 (bonus) — Memory limit too low → <code>OOMKilled</code></b></summary>

- `kubectl get pods` → `OOMKilled` / `CrashLoopBackOff`
- `kubectl describe pod <pod>` → `Last State: Terminated, Reason: OOMKilled, Exit Code: 137`
- `kubectl logs` shows nothing useful — the kernel killed the process.
- Cause: `limits.memory: 20Mi` — the Python app needs more than that just to start.
- Fix: `kubectl apply -f final/k8s/05-backend-deployment.yaml`
</details>

<details>
<summary><b>6 (bonus) — Impossible CPU request → <code>Pending</code></b></summary>

- `kubectl get pods` → a new Pod stuck in `Pending`
- `kubectl describe pod <pod>` → `FailedScheduling: 0/3 nodes are available: ... Insufficient cpu`
- Cause: `requests.cpu: "64"` — no node has 64 CPUs. Requests are for **scheduling**.
- Fix: `kubectl apply -f final/k8s/05-backend-deployment.yaml`
</details>
