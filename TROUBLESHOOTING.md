# Troubleshooting: Metrics Pipeline and HPA Failures

The metrics pipeline is Metrics Server -> kubelet/cAdvisor -> HPA. When `make verify-metrics` reports a failed check, the failure maps to one of the three layers below. Each entry lists the symptom, the diagnostic commands, and the fix.

## 1. Metrics Server Not Scraping

**Symptom:** `make verify-metrics` check 2 fails; `kubectl top pods` returns an error or no rows.

**Diagnosis:**

```
kubectl get pods -n kube-system -l k8s-app=metrics-server
kubectl describe pod -n kube-system -l k8s-app=metrics-server
kubectl logs -n kube-system -l k8s-app=metrics-server
kubectl top nodes
kubectl get --raw /apis/metrics.k8s.io/v1beta1
```

- If the metrics-server pod is not Running, the Deployment did not come up — inspect events with `kubectl describe pod -n kube-system -l k8s-app=metrics-server`.
- If `kubectl top nodes` works but `kubectl top pods` returns nothing, per-pod metrics are not yet collected — Metrics Server scrapes on a ~15s cadence; wait up to a minute after `make deploy` and re-run.
- If the `metrics.k8s.io/v1beta1` API group is missing, Metrics Server never registered — re-run `make deploy`, which waits for the metrics-server pod before applying the app and HPA.

**Fix:** Redeploy with `make deploy`. The manifests already pass `--kubelet-insecure-tls` for kind; no kubelet patch is needed.

## 2. Missing CPU Resource Requests

**Symptom:** `make verify-metrics` check 3 fails; `kubectl get hpa` shows `<unknown>` in the TARGETS column.

**Diagnosis:**

```
kubectl get hpa
kubectl describe pod -l app=fastapi-app | grep Requests
```

The HPA computes utilization as measured CPU divided by the container's CPU request. If `grep Requests` prints nothing, the Deployment has no `resources.requests.cpu`, utilization is undefined, and the HPA reports `<unknown>` even though Metrics Server is scraping correctly.

**Fix:** Add a CPU request to the container spec in `k8s/app/deployment.yaml` — the shipped manifest sets `cpu: 200m` and `memory: 256Mi`. Then re-run `make deploy`. No `limits` are set by design; limits throttle CPU and distort the scaling picture.

## 3. Prime Ceiling Too Low to Trigger the 60% Target

**Symptom:** `make verify-metrics` check 4 fails — CPU does not rise after a single `/compute-heavy` request; or under `make load-test` the HPA never leaves 1 replica at full load.

**Diagnosis:**

```
kubectl top pods
curl http://localhost:8080/compute-heavy
kubectl top pods
```

`/compute-heavy` runs a synchronous prime-count loop up to `PRIME_LIMIT` (default 100000) in `app/main.py`. On fast hardware the loop finishes in a few hundred milliseconds, so a single request barely moves the pod's CPU average and the HPA never approaches its 60% target. One request measures roughly 300ms at the default ceiling on a typical dev machine.

**Fix:** Raise the ceiling — set the `PRIME_LIMIT` environment variable to 200000 or 500000 (in `app/main.py`'s default, or as an env entry in `k8s/app/deployment.yaml`) — then re-run `make deploy`. Under load, `make load-test` with 200 Locust users drives CPU well past the 60% target and scales the Deployment to 5 replicas.
