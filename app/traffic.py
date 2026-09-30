"""Demo helper — continuously call the backend Service from inside the cluster.

    kubectl run traffic --rm -it --restart=Never --image=devops-live-api:1.0 -- python traffic.py

Prints which version + which pod answered each request. Ctrl+C to stop.
"""
import json
import sys
import time
import urllib.request

url = sys.argv[1] if len(sys.argv) > 1 else "http://backend/"

while True:
    try:
        data = json.load(urllib.request.urlopen(url, timeout=2))
        print(f"version={data['version']}  pod={data['pod']}", flush=True)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR {exc}", flush=True)
    time.sleep(0.5)
