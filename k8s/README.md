# k8s/ — live workspace

The manifests we write during the live, in the order we create them.
Full script: [`../docs/RUNBOOK-INGRESS.md`](../docs/RUNBOOK-INGRESS.md).

```text
k8s/
├── cluster.yaml          # Part 2 — kind cluster, control-plane ready for Ingress (localhost:8081/8443)
├── db/
│   ├── deployment.yaml   # Part 3 — PostgreSQL
│   └── service.yaml      # Part 3 — devops-live-db:5432
└── api/
    ├── deployment.yaml   # Part 4 — API (+ readinessProbe in Part 5)
    ├── service.yaml      # Part 4 — devops-live-api:8000
    └── ingress.yaml      # Part 6 — http://api.localhost:8081
```

```bash
make cluster ns load load-postgres   # cluster + images
kubectl apply -f k8s/db/ -f k8s/api/service.yaml -f k8s/api/deployment.yaml
make ingress-controller              # ingress-nginx, pinned to the control-plane
kubectl apply -f k8s/api/ingress.yaml
```

**Made a typo and lost the flow?** Restore the committed version and reapply:

```bash
git checkout k8s/ && make deploy
```
