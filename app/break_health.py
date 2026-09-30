"""Demo helper — run inside a pod to make its liveness probe fail:

    kubectl exec -n devops-live <pod-name> -- python break_health.py
"""
import urllib.request

req = urllib.request.Request("http://localhost:8000/admin/break-health", method="POST")
print(urllib.request.urlopen(req).read().decode())
