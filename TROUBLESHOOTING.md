# Troubleshooting: Metrics Pipeline and HPA Failures

The metrics pipeline runs Metrics Server to kubelet cAdvisor to HPA. When `make verify-metrics` flags a check, the failure maps to one of three layers. Each entry lists the symptom, the diagnostic commands, and the fix.

## 1. Metrics Server Not Scraping

**Symptom.** `make verify-metrics` check 2 fails; `kubectl top pods` errors out or returns no rows.

**Diagnosis.**

```
kubectl get pods -n kube-system -l k8s-app=metrics-server
kubectl describe pod -n kube-system -l k8s-app=metrics-server
kubectl logs -n kube-system -l k8s-app=metrics-server
kubectl top nodes
kubectl get --raw /apis/metrics.k8s.io/v1beta1
```

- A missing Running status on the metrics-server pod means the Deployment never came up; inspect events with `kubectl describe pod -n kube-system -l k8s-app=metrics-server`.
- `kubectl top nodes` working while `kubectl top pods` returns nothing means per-pod metrics have not been collected yet. Metrics Server scrapes on a cadence near 15 seconds; wait up to a minute after `make deploy` and re-run.
- A missing `metrics.k8s.io/v1beta1` group means Metrics Server never registered. Re-run `make deploy`; its readiness gate waits for the metrics-server pod before applying the app and HPA.

**Fix.** Redeploy with `make deploy`. The manifests already pass `--kubelet-insecure-tls` for kind; no kubelet patch is needed.

## 2. Missing CPU Resource Requests

**Symptom.** `make verify-metrics` check 3 fails; `kubectl get hpa` shows `<unknown>` in the TARGETS column.

**Diagnosis.**

```
kubectl get hpa
kubectl describe pod -l app=fastapi-app | grep Requests
```

The HPA divides measured CPU by the container's CPU request to obtain utilization. With no `resources.requests.cpu` in the Deployment, that division is undefined, and the HPA prints `<unknown>` even while Metrics Server scrapes correctly. An empty grep output identifies the cause.

**Fix.** Add a CPU request to the container spec in `k8s/app/deployment.yaml`. The shipped manifest sets `cpu: 200m` and `memory: 256Mi`. Then re-run `make deploy`. Limits stay unset on purpose; throttling distorts the utilization picture.

## 3. Prime Ceiling Too Low to Trigger the 60% Target

**Symptom.** `make verify-metrics` check 4 fails; CPU does not rise after a single GET /compute-heavy request. Under `make load-test` the HPA may also hold one replica at full load.

**Diagnosis.**

```
kubectl top pods
curl http://localhost:8080/compute-heavy
kubectl top pods
```

GET /compute-heavy counts primes up to `PRIME_LIMIT` (default 100000) in `app/main.py`, synchronously. On fast hardware the loop finishes in a few hundred milliseconds, so one request barely moves the pod's CPU average and the HPA never approaches its 60% target. Repeat the request several times in quick succession, or raise the ceiling, and the delta becomes visible.

**Fix.** Raise the ceiling: set `PRIME_LIMIT` to 200000 or 500000, either as an env entry in `k8s/app/deployment.yaml` or by changing the default in `app/main.py`. Redeploy. At 200 Locust users the workload drives CPU well past 60% and the Deployment scales to five replicas.
