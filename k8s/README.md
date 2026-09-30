# k8s/ — live workspace

This folder is intentionally empty. During the live we write the manifests here,
one by one, and apply them:

```bash
kubectl apply -f k8s/deployment.yaml
```

Suggested files, in the order we create them:

```text
k8s/
├── deployment.yaml            # Part 3 — backend Deployment
├── configmap.yaml             # Part 4 — non-sensitive config
├── secret.yaml                # Part 4 — DB credentials
├── postgres-deployment.yaml   # Part 5
├── postgres-service.yaml      # Part 5
└── service.yaml               # Part 6 — backend Service
```

**Made a typo and lost the flow?** The known-good version lives in `../final/k8s/`:

```bash
kubectl apply -f final/k8s/
```
