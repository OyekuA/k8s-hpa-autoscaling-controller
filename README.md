# k8s-hpa-autoscaling-controller

## Abstract

Vertical capacity planning fails at the moment demand turns sharp. A pod sized for a quiet workload sits idle most of the day, then a burst arrives and latency collapses. This project replaces that guesswork with Kubernetes Horizontal Pod Autoscaling, demonstrated end to end on a local single-node kind cluster. The workload is a FastAPI microservice exposing one synchronous endpoint, GET /compute-heavy, which blocks the uvicorn event loop while counting primes to a configurable ceiling (PRIME_LIMIT, default 100,000) by trial division. Blocking is deliberate. CPU utilization then tracks request concurrency almost linearly, which gives the autoscaler a clean signal to react to. A HorizontalPodAutoscaler built on the stable autoscaling/v2 API holds the Deployment at 60% average CPU utilization, between 1 and 5 replicas, fed exclusively by Metrics Server through the metrics.k8s.io API. Locust supplies 200 concurrent users at a 20 user/s ramp for 5 minutes, delivered through kubectl port-forward. Prometheus watches the same cAdvisor stream as a read-only observer and takes no part in scaling decisions. Under sustained load the Deployment climbs from 1 pod toward 5; once load stops it walks back down one pod per 30 seconds. Pod timelines, latency percentiles, and CPU series land on disk as evidence.

## Quick Start

Prerequisites: Docker Desktop (Windows with the WSL2 backend, or native Linux/macOS), kind, kubectl, locust, and make.

Run the cycle from a clean shell:

```
make check-prereqs
make cluster
make deploy
make verify-metrics
make load-test
```

Three evidence files appear in the repo root: `load-test-results_stats.csv`, `load-test-results_stats_history.csv`, and `load-test-pods.log`. The terminal prints `=== LOAD TEST COMPLETE ===` when the run finishes. Port-forward the Prometheus service (`kubectl port-forward svc/prometheus 9090:9090`), run the query in Methodology, and save the graph to `docs/screenshots/prometheus-cpu.png`. Also capture the pod timeline from `load-test-pods.log` into `docs/screenshots/pod-scaling.png`.

Tear down once the evidence is saved:

```
make teardown
```

## Architecture

```
                 kubectl port-forward
                 svc/fastapi-app: 8080 -> 80
                            |
  User -> Locust ----------+----------> FastAPI Deployment
  (200 users,                             (fastapi-app, 1-5 replicas)
   20/s ramp,                              |
   5 min,                                  |  per-pod CPU usage
   GET /compute-heavy)                     |  (kubelet cAdvisor)
                                          v
                                  Metrics Server
                                  (metrics.k8s.io API)
                                          |
                                          |  utilization %
                                          |  (usage / 200m request)
                                          v
                                  HPA fastapi-app-hpa
                                  (autoscaling/v2,
                                   60% target,
                                   min 1, max 5)

  Prometheus: read-only observer, scrapes cAdvisor every 15s,
  no connection to the autoscaling loop.
```

### Data flow

**Request path.** `make load-test` backgrounds `kubectl port-forward svc/fastapi-app 8080:80`, mapping localhost:8080 onto the ClusterIP Service's port 80. Locust then drives GET /compute-heavy from 200 users, added at 20 users per second, so full load arrives about 10 seconds in. The run lasts 5 minutes. Each request executes a synchronous prime count on the single uvicorn worker's event loop; the handler never yields, so per-pod CPU grows with concurrency while the Service balances requests across whatever replicas exist.

**Autoscaling loop.** Metrics Server v0.9.0 scrapes the kubelet cAdvisor endpoint and publishes per-pod CPU through the metrics.k8s.io API. The HPA controller polls that API and computes utilization as current usage divided by the 200m CPU request, then writes replica counts that push average utilization toward 60%, clamped to the 1 to 5 range. A behavior block slows the descent: 60 seconds of stabilization plus one pod removed per 30 seconds. Metrics Server is the only input to that loop.

**Observability.** Prometheus runs as a separate pod and scrapes the same cAdvisor source every 15 seconds (scrape_interval in `k8s/prometheus/configmap.yaml`). It answers the dashboard query in Methodology. It never feeds the HPA.

## Methodology

The experiment is reproducible with make alone. Every step either produces evidence or verifies the pipeline that generates it.

### Procedure

1. `make deploy` builds the fastapi-hpa:latest image, loads it into the kind cluster, then applies Metrics Server, Prometheus, the app, and the HPA in dependency order, waiting on pod readiness between the critical stages.
2. `make verify-metrics` runs four pass/fail checks: metrics-server pods Running, kubectl top pods returning rows, the HPA target numeric rather than `<unknown>`, and a single GET /compute-heavy request lifting pod CPU. Failures route to [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
3. `make load-test` runs the whole experiment in one command and writes the evidence files.
4. `kubectl port-forward svc/prometheus 9090:9090` opens the Prometheus expression browser at http://localhost:9090; the query below runs across the test window.
5. `make teardown` destroys the cluster once the evidence files are safe.

### Load profile

| Parameter | Value |
| --- | --- |
| Tool | Locust (`locustfile.py`: `HttpUser`, `wait_time = constant(0)`) |
| Users | 200 concurrent |
| Ramp rate | 20 users/s (full load in about 10 s) |
| Duration | 5 minutes |
| Endpoint | GET /compute-heavy |
| Host | http://localhost:8080 via `kubectl port-forward svc/fastapi-app 8080:80` |

### Metrics collected

- **CPU utilization** the HPA target column from `kubectl get hpa` (a percentage of the 200m CPU request) and `kubectl top pods` (raw millicores).
- **Pod count timeline** a backgrounded `kubectl get pods -w` stream, appended to `load-test-pods.log` during the run.
- **Latency percentiles** Locust p50, p95, and p99, both aggregated and per second.

### Measurement tools

**Locust.** The `make load-test` target invokes it headless with exactly:

```
locust -f locustfile.py --headless -u 200 -r 20 --run-time 5m --csv load-test-results --host http://localhost:8080
```

The `--csv` flag writes `load-test-results_stats.csv` (end-of-run aggregates: request counts, RPS, failures, latency percentiles, plus the TOTAL row) and `load-test-results_stats_history.csv` (per-second history, the file that exposes the pre-scale and post-scale contrast). Failures and exceptions files are emitted as byproducts.

**kubectl.** During the test the target backgrounds the port-forward and the pod watch, both appending to `load-test-pods.log`. That log reconstructs the 1 -> N -> 1 sequence.

**Prometheus.** The cAdvisor job scrapes every 15 seconds. The dashboard query is:

```
rate(container_cpu_usage_seconds_total{namespace="default",pod=~"fastapi-app.*"}[1m])
```

A 1-minute rate window means the series only appears after roughly 60 to 75 seconds of samples. Set the graph range to span the full run.

## Results

The evidence below is produced by a single complete run of Methodology. Screenshots live in `docs/screenshots`; the numeric artifacts (`load-test-pods.log`, `load-test-results_stats.csv`, `load-test-results_stats_history.csv`) are written to the repo root by `make load-test`.

### Scaling timeline

`load-test-pods.log` carries the pod count minute by minute. The expected shape is mechanical: one pod at idle, additions as utilization crosses 60%, a plateau at five replicas while load holds, then the slow one-pod-per-30-second descent after the run ends and the stabilization window lapses.

![Pod scaling timeline: kubectl get pods -w capture showing the 1 to 5 to 1 sequence](docs/screenshots/pod-scaling.png)

### CPU utilization

Prometheus renders the Methodology query over the run window. The series shows the CPU spike climbing as users ramp, the per-pod drop as replicas multiply, and the return to idle after load stops. The HPA target column in `kubectl get hpa` moves in the same direction in utilization terms.

![Prometheus CPU series: rate of container_cpu_usage_seconds_total across the load window](docs/screenshots/prometheus-cpu.png)

### Latency

`load-test-results_stats.csv` reports p50, p95, and p99 for the whole run. `load-test-results_stats_history.csv` shows the same percentiles per second, which is the view that isolates the pre-scale and post-scale windows. The interpretation procedure sits in Analysis.

## Analysis

**Why latency drops after scale-up.** The handler is synchronous and the pod runs one uvicorn worker, so each replica processes requests strictly serially. Queue depth grows with concurrency while replicas are few; the p99 climbs with that queue. When the HPA adds pods, the parallel handler count rises and the queue drains faster. The per-second percentile history quantifies exactly that contrast between the one-pod window and the five-pod plateau.

**Reaction time.** The HPA controller polls metrics on a 15-second sync period by default, and the scale-up policy doubles capacity per evaluation, capped at 4 pods. Scale-up therefore lands within a few evaluation cycles of the 60% crossing. Scale-down is deliberately slower: a 60-second stabilization window guards against flapping, then pods leave at one per 30 seconds. The asymmetry is intentional; shedding capacity too fast causes oscillation.

**Stabilization.** At five replicas, per-pod utilization falls because the same request rate spreads across more handlers. The controller holds the count while utilization sits under target and the window runs.

**Anomalies.** The first minute after deploy can show `<unknown>` in the HPA target; metrics take a few scrape cycles to exist. Port 8080 already in use breaks the port-forward. A slow first image pull keeps the pod in ContainerCreating. TROUBLESHOOTING.md diagnoses each.

## Repository Layout

```
app/                  FastAPI microservice (main.py, requirements.txt)
k8s/
  metrics-server/     Metrics Server manifests (deployment, rbac, service)
  prometheus/         Prometheus manifests (deployment, rbac, service, configmap)
  app/                FastAPI Deployment + ClusterIP Service
  hpa/                HorizontalPodAutoscaler (60% CPU, 1-5 replicas)
Dockerfile            Container build for the FastAPI service
locustfile.py         Locust load generator for GET /compute-heavy
Makefile              Orchestration targets (check-prereqs through demo)
kind-config.yaml      Single-node kind cluster definition
docs/screenshots/     Evidence screenshots (pod scaling, Prometheus CPU graph)
TROUBLESHOOTING.md    The three common failure modes and their diagnostics
```

## Limitations & Future Work

Single-node kind bounds the demo to pod-level scaling; node autoscaling never enters the picture. All replicas share one node's CPU, so context-switch overhead grows with pod count and per-pod latency gains shrink past a few replicas. The HPA consumes resource metrics only; the Prometheus adapter path is excluded on purpose. Prometheus holds its data in memory for the session; nothing persists. Resource limits are deliberately absent, because throttling distorts the utilization picture the whole demo exists to show. Readiness probes are absent beyond the deploy-time waits; the demo trades them for simplicity.

Future work: Grafana dashboards on top of the Prometheus series, a custom metrics adapter so the HPA can scale on queue depth instead of CPU, and CI/CD that runs the whole cycle in a hosted cluster and publishes the evidence artifacts.
