# Transit telemetry pipeline — design and decision record

Working name: `transit-pipeline` (rename before first commit if a better one comes up).

This document is the authoritative context for the project. It records not just *what* was decided but *why*, because the primary purpose of this project is to be defensible in a live interview. If a decision here is changed during implementation, update this file with the new reasoning.

---

## 1. Purpose

This is a portfolio project targeting Production Engineer and SRE roles (Meta PE, Google SRE, Cloudflare, Datadog).

**The gap it fills:** every existing project in the portfolio is something that gets *run* — a simulation launched on demand, a tool invoked, an offline model trained. Nothing is a continuously running service with a measured SLO, an error budget, and a documented incident. That is the clearest hole for PE/SRE loops, and this project exists to fill it.

**The consequence:** the visualization is the least important part of this project. The map exists so the system has a reason to be up and a face to show. The valuable artifacts are the SLO, the alerting, the runbook, and the postmortem. Do not spend time on frontend polish at the expense of those.

**Secondary benefit:** hands-on Kubernetes and Terraform, which doubles as CKA preparation.

**Timeline context:** this is an October–December interview asset, not a September CV line. It must not displace algorithm practice or delay job applications.

---

## 2. Non-goals

Explicitly out of scope for the project entirely. Do not build these.

- Authentication or user accounts
- Arrival-time prediction, ETA modelling, or any ML
- Multiple cities
- A historical replay UI
- Mobile app or responsive design work
- Autoscaling, multi-region, high availability
- Anything that makes the map prettier once it renders correctly

Deferred to v1 (see section 9) rather than cut: compression and retention, the full-fleet scale test, the GBFS second feed.

---

## 3. Data source

**Primary: SPTrans Olho Vivo API** (São Paulo bus fleet).

- Free, token-gated. Register at the SPTrans developer area to obtain a key.
- Auth flow: POST with the token to authenticate, then subsequent requests use the resulting session.
- The full-fleet position endpoint returns every mapped vehicle with `lat`/`lon` and a UTC capture timestamp in ISO 8601.
- Fleet size is roughly 15,000 vehicles.
- The JSON schema is terse: fields like `l` (lines), `vs` (vehicles), `py` (latitude), `px` (longitude), `ta` (capture timestamp), `p` (vehicle prefix), `qv` (vehicle count). Map these to readable Go struct field names with JSON tags.

**Secondary, v1 only: GBFS bike share.**
- `https://saopaulo.publicbikesystem.net/customer/gbfs/v3.0/gbfs.json`
- No authentication, standardized open spec.
- Purpose is to prove the pipeline handles a second feed shape, not to add features.

**Rejected: trains (CPTM/Metrô).** They publish line status, not vehicle positions. Building on approximated positions adds fragility without adding signal.

---

## 4. Decisions and their justifications

Each decision below includes the reasoning that must survive being challenged in an interview. Where a decision is weak or is a deliberate over-engineering choice, that is stated openly — honest acknowledgment is the correct posture, not a liability.

### 4.1 Kubernetes

**Decision:** deploy on Kubernetes (k3s, single node).

**The honest part, state it first:** for one ingester and one database, Kubernetes is over-engineering. A systemd unit would do the job. Claiming it was "the right tool for the scale" invites the question "what was your scale requirement?" — and there isn't one.

**The defensible framing:** it was chosen deliberately to learn its failure modes on a system I own, and two of its properties earned their keep:

1. **Declarative reconciliation of a long-running process.** The ingester must stay up. When it OOMs or the node reboots, something must restart it with a backoff that does not hammer the upstream API. That is the controller loop, and hand-rolling it is how people end up with bad restart storms.
2. **Health probes as a forcing function.** Kubernetes makes you state explicitly what "healthy" means for this process. For an ingester the answer is not "the process is alive" — it is "it wrote data recently." Defining that probe is the actual design work.

**A third reason, added by the portability constraint (see section 6):** Kubernetes manifests are the portable unit. The same Layer B deploys unchanged to Oracle, Hetzner, or bare metal. That is a genuine, non-rationalized benefit of the abstraction.

**What does *not* justify it, and should be conceded before being asked:** autoscaling (load is constant), service discovery (two services), rolling deploys (nobody is watching), multi-node scheduling (one node).

### 4.2 Go for the ingester

**Decision:** Go.

**The reason that does NOT hold, do not use it:** performance. Two HTTP requests a minute and 500 row writes. Python would handle this without noticing. Claiming Go for speed demonstrates picking tools by reputation.

**The three reasons that hold:**

1. **The concurrency model matches the problem shape.** The ingester is a fan-in: several independent poll loops feeding a single batching writer, with an HTTP server for `/metrics` alongside. Goroutines writing to a buffered channel drained by one writer goroutine expresses this directly. The channel buffer size is an explicit, tunable backpressure boundary — when the DB is slow, the channel fills, and the drop-vs-block decision becomes a visible line of code rather than emergent behaviour.
2. **Deployment shape, especially on ARM.** A static binary means a `scratch` or distroless image around 15–20 MB versus 150 MB+ for a Python base. Two of the three candidate hosts are arm64; with Go that is `GOARCH=arm64` cross-compiled from the laptop. With Python on ARM you are at the mercy of published wheels and end up compiling C extensions inside a Docker build.
3. **Ecosystem alignment.** Prometheus, Grafana, Kubernetes, Terraform, Docker and etcd are all written in Go. Being able to read the source of the tool that is misbehaving is a real PE skill. Go is also a genuine gap in the current CV, and Cloudflare, Datadog, and Google SRE would all notice it.

**What it costs:** slower to a working v0, concentrated almost entirely in unmarshalling the terse SPTrans schema. Also loses pandas for ad-hoc exploration, though that analysis happens in SQL anyway.

**Mitigation, do this first:** write a throwaway ~20-line Python script to hit the API, print the JSON, and learn what the fields actually contain and where nulls appear. Then write the real ingester in Go against a schema already understood. Delete the Python script; it is not part of the deliverable.

### 4.3 Long-running Deployment, not a CronJob

**Decision:** a single-replica Deployment running an internal ticker.

**Why:** a CronJob every 45 seconds means process startup ~1,920 times a day, no in-memory state between runs, no persistent connection pool, and no way to implement adaptive backoff across invocations.

**The cost accepted:** a long-running process can hang without dying. That is why the liveness probe asserts write recency rather than process liveness (see 4.7).

### 4.4 Postgres with TimescaleDB for positions; Prometheus for pipeline telemetry only

**Decision:** vehicle positions go in Postgres/Timescale. Prometheus never sees per-vehicle data.

**Why:** 15,000 vehicle IDs labelled into Prometheus would be 15,000 time series. Prometheus storage is built for bounded-cardinality aggregate telemetry, not per-entity event data. The clean boundary — **Prometheus monitors the pipeline, Postgres stores the payload** — is a distinction PE interviews actively test.

**Why Timescale over plain Postgres:** hypertables give automatic time-based partitioning, and compression plus continuous aggregates are the v1 retention mechanism (see 4.6). Note honestly that in v0 those features are unused, so v0 alone would not justify Timescale over plain Postgres — it is installed in v0 so that v1 does not require a migration.

### 4.5 45-second polling interval

**Why:** do not sample faster than the source updates. The AVL units report on their own cadence; polling every 5 seconds returns the same data several extra times, burns quota, and multiplies write volume for zero information gain. Sample rate is derived from the signal, not from "as fast as possible."

**Measured in step 0 (2026-08-22):** the per-vehicle update cadence is a firm **~45 s** ceiling (median 44 s, p90 45 s, max 45 s over a 150 s window on line 3459-10 / cl=402), *not* the 30 s originally assumed. The poll interval is therefore set to **45 s** to sample at the source cadence, and the SLO threshold is re-derived from it (see §5.2). This also revised the row-volume arithmetic in §4.6 and the CronJob-startup count in §4.3.

### 4.6 Scope and retention

**The arithmetic, which must be reproducible on a whiteboard:**

- Full fleet: 15,000 vehicles × 1.33 samples/min (45 s cadence, measured in step 0) = **~28.8M rows/day**.
- Row cost: ~28 bytes of data (`vehicle_id`, `line_id`, `ts`, `lat`, `lon`) plus a 23-byte Postgres tuple header plus alignment plus index entries ≈ **~100 bytes all-in**.
- Full fleet uncompressed: **~2.9 GB/day**, which fills 200 GB in about ten weeks. Not viable.
- Subset of three corridors (~25 lines, ~500 vehicles at peak): **~0.96M rows/day, ~96 MB/day**. Survivable for well over a year with no compression at all.
- With Timescale columnar compression (expect 10–20× on this shape — low-cardinality repeating IDs, delta-encodable timestamps): **~5–10 MB/day**.

**Note the conclusion:** compression, not subsetting, does the heavy lifting.

**v0 does not implement compression or retention.** At ~96 MB/day on a subset there is well over a year of headroom, so it is not needed. It is a v1 item because the *measurement* makes a good story, not because the system requires it. Be honest about that distinction — implementing a mechanism you do not need and calling it necessary is the failure mode.

**Batch inserts, in v0.** One INSERT per vehicle per poll is 500 round trips every 45 seconds. Use `COPY` or multi-row inserts per drained batch. This is where the buffered-channel design pays off.

### 4.7 Health probes

**Liveness:** must assert that the last *successful write* was within N seconds — not merely that the HTTP handler responds. A hung poll loop with a healthy HTTP server is precisely the failure being defended against. If the assertion fails, let Kubernetes kill and restart the pod.

**Readiness (read API):** asserts the database connection is up.

**Why this distinction matters:** using liveness where readiness belongs causes restart storms, and it is one of the most common real Kubernetes incidents. Getting it right is a deliberate signal.

### 4.8 Secrets

The SPTrans token lives in a Kubernetes Secret referenced by environment variable. Never in the image, never in the repo.

**State the limitation openly:** a base64-encoded Secret is not encrypted at rest by default. Knowing the weakness of the mechanism used is better than assuming it is secure.

**As built (step 6).** Three practices follow from "never in the repo":

- **Secrets are created out-of-band and never applied from a file.** `scripts/remote-secrets.sh`
  renders each Secret locally with `kubectl --dry-run=client -o yaml` and pipes it over SSH into
  `kubectl apply -f -`. No secret value is ever a command-line argument of a process on the box,
  where it would sit in `ps` output for anything else running there to read. Values come from the
  gitignored `.env`, and only the one key being used — the token secret is built from a grepped
  single-line env file, not from the whole of `.env`.
- **The production database password is alphanumeric by construction.** It is interpolated into a
  `postgres://` DSN, where a `/`, `@` or `:` corrupts the connection string quietly rather than
  failing loudly. Generating from a restricted alphabet is cheaper and safer than percent-encoding
  correctly at every use site.
- **Deploy access uses a dedicated passphrase-less key**, not the operator's personal key.
  Automation cannot answer a passphrase prompt, and a key scoped to one job can be revoked from the
  box without disturbing anything else. The personal key keeps its passphrase and stays the human
  login. This is a deliberate trade — one unencrypted private key on disk, in exchange for not
  weakening a key used elsewhere.

The registry pull credential is a Secret too: the images are in a private GHCR repo, so the kubelet
authenticates with a `dockerconfigjson` Secret rather than the images being made public to avoid it.

### 4.9 Read API and map

- Serve current positions from a materialized "latest position per vehicle" view. Do **not** run `SELECT DISTINCT ON` over the full history table per request — the planner will not save you at tens of millions of rows.
- Map: Leaflet, static, hosted on Cloudflare Pages alongside the existing portfolio.
- Keep it deliberately unimpressive.

**CORS is an allowlist, not `*` (step 6).** The page and the API are on different origins by
construction — Pages serves the map, the tunnel serves the API — so the browser demands an explicit
`Access-Control-Allow-Origin`. The skeleton answered `*`, which on a *public* endpoint means script
on any page on the internet can read it. `CORS_ALLOW_ORIGIN` is now a comma-separated allowlist; the
API echoes back whichever listed origin actually asked and adds `Vary: Origin`, so the CDN in front
cannot serve one origin a header minted for another. A list rather than a single value is precisely
what lets the *same* manifest serve production and `make map` on localhost — §6's requirement that
Layer B not fork per environment. Per-deployment Pages preview URLs are deliberately not listed.

---

## 5. Observability specification

### 5.1 Metrics

Exactly four to start. Each one exists to catch a specific failure the others miss.

| Metric | Type | Why it exists |
|---|---|---|
| `feed_last_success_timestamp` | Gauge (Unix seconds) | Alert on `time() - metric > 120`. A boolean says nothing about *how long* it has been broken; a counter that stops incrementing is indistinguishable from a target that stopped being scraped. A timestamp gauge expresses the user-facing property directly and is independent of scrape interval and `rate()` windows. |
| `positions_ingested_total` | Counter | Catches the silent failure the timestamp misses: upstream returns HTTP 200 with an empty payload. Last-success looks fresh, nothing is ingested. `rate(...[5m]) == 0` catches it. **Success at the transport layer is not success at the semantic layer.** |
| `upstream_request_duration_seconds` | Histogram | Histograms store additive bucket counts, so quantiles can be computed at query time and aggregated across instances. Summaries pre-compute quantiles inside each instance and cannot be re-aggregated — a p99 of an average is not the average of the p99s. |
| `parse_failures_total{reason=...}` | Counter, bounded label | `reason` takes a fixed small set of values (`malformed_json`, `missing_coords`, `bad_timestamp`). **Never** label by `vehicle_id` or `line_id` — each label combination is a separate series and that is the cardinality explosion. Demonstrating cardinality discipline before adding a label is the signal. |

Add `samples_dropped_total` when the buffered-channel backpressure policy is implemented (see 4.2).

Everything else goes to structured logs. **Metrics for detection, logs for diagnosis.**

### 5.2 SLO

**SLI: data freshness** — the age of the most recent successfully written position sample.

**Why freshness rather than availability or latency:** availability answers "did my API return 200?" For a data pipeline that is the wrong question. A serving API returning three-hour-old positions looks perfectly healthy and is useless. Freshness is the property a user would actually notice. Choosing the SLI that matches the user experience over the one that is easiest to measure is most of the skill in this area.

**Target: p99 freshness under 120 seconds, measured over a 30-day rolling window.**

**Why p99, bracketed from both sides:**
- p50 is useless — half the samples being fresh says nothing, since failures live entirely in the tail.
- p99.9 sounds more rigorous but allows ~86 seconds of budget per day. The upstream is a municipal API with maintenance windows longer than that, and it is not under my control. That guarantees a permanently exhausted budget and alerts that get ignored — worse than having no SLO.
- p99 gives ~14.4 minutes of budget per day. Enough to absorb a normal upstream hiccup, not enough to absorb the ingester being down for an hour. It fires on things that are fixable.

**Principle to be able to state:** an SLO that cannot be met because of a dependency you do not control is not a stretch goal, it is a broken alert.

**Why 120 seconds:** two 45 s poll cycles plus write latency. One missed cycle is normal jitter and should not page; two consecutive misses is a real problem. The threshold is derived from the system's measured 45 s cadence (step 0), not chosen because it is round.

**Scope caveat, state it honestly:** the SLO covers the pipeline only. Upstream outages consume the error budget even though they are not fixable locally, which is the correct behaviour for a user-facing SLI but means the number measures the whole dependency chain, not just my code.

### 5.3 Alerting

**Burn-rate alerting, not a static threshold.** A plain "freshness > 120s" alert fires on every transient blip and trains you to ignore it. Burn rate asks "at the current error rate, how fast am I consuming the month's budget?" — fast burn over a short window pages, slow burn over a long window files a ticket. This is alerting on consequences rather than symptoms.

Route the page somewhere it will actually be seen. An alert nobody receives is not an alert.

---

## 6. Portability: Layer A and Layer B

**Constraint:** v0 must deploy to any of three hosts — Oracle Cloud A1 Always Free, a small Hetzner VPS, or personally owned hardware — without redesign and without meaningful cost.

**Consequence:** the host is a swappable dependency, not part of the architecture. The stack splits in two.

**Layer A — machine provisioning.** Cloud-specific, Terraform. On Oracle: instance, VCN, security list, block volume. On Hetzner: a different provider, roughly fifteen lines. On owned hardware: a no-op. Thin and disposable.

**Layer B — everything that runs on the machine.** A bootstrap script that installs k3s, plus the Kubernetes manifests. Byte-identical across all three hosts. **This is the real deliverable.**

**The interview line:** *"I kept the cluster layer host-agnostic so the platform stayed a swappable dependency. Terraform provisions a VM where one needs provisioning; on bare metal that layer is empty."*

Four rules that follow, and must be honoured from the first commit:

**6.1 Multi-arch images.** Oracle A1 is arm64. A Hetzner CAX is arm64, a CX is amd64. The development laptop is amd64. Build with `docker buildx` for `linux/amd64,linux/arm64` from the start. Retrofitting this after hardcoding an arch is pure wasted work.

**6.2 A 4 GB memory budget, not 12.** Size for the smallest plausible host so the largest is comfortable. Target allocation:

| Component | Budget |
|---|---|
| Postgres/Timescale | 1 GB |
| Prometheus (15-day retention) | 1 GB |
| Grafana | 256 MB |
| Ingester | 128 MB |
| Read API | 128 MB |
| cloudflared (tunnel) | 128 MB |
| k3s + OS headroom | ~1 GB |

Set explicit `requests` and `limits` on every pod. This is correct practice independently and is a common interview question.

The cloudflared row was added at step 6, when the tunnel stopped being a diagram
box and became a pod. That brings the table to ~3.6 GB against 4 GB. The remaining
margin is thin on purpose: the budget exists to force the choice between components,
not to leave comfortable room for one more.

**Direct implication: do not install `kube-prometheus-stack`.** It pulls in node-exporter, kube-state-metrics, and a large default rule set, and will not sit comfortably in 4 GB. Deploy Prometheus, Alertmanager, and Grafana as three plain Deployments with hand-written config. Slower, but the scrape config is then actually understood — which matters more here than convenience.

**6.3 Local storage only.** Use the k3s built-in local-path provisioner. No cloud CSI drivers, no managed database. **State the trade-off honestly:** data lives on a single disk with no replication, so a nightly `pg_dump` to a second location is the durability story, not the storage layer.

**6.4 Cloudflare Tunnel for ingress.** This is what makes the owned-hardware option viable at all — residential connections are typically behind CGNAT with no inbound public IP. The tunnel sidesteps that and provides TLS. It also means no cloud load balancer on any host, which is usually the line item that quietly costs money.

**As built (step 6).** The tunnel is *locally managed*: its routing lives in `k8s/cloudflared.yaml`
in this repo, not in the Cloudflare dashboard. Dashboard-managed tunnels behave identically, but they
move a load-bearing piece of the system somewhere with no version history, no diff and no review.
cloudflared runs as an ordinary in-cluster Deployment reading that ConfigMap, with the tunnel's
credentials mounted from a Secret.

**The security consequence is the part worth stating.** Because ingress is an *outbound* connection,
the host firewall opens port 22 and nothing else. There is no inbound 80/443 rule to write, and
— verified from off-host once k3s was up — the Kubernetes API on 6443 and the kubelet on 10250 are
unreachable from the internet. Remote `kubectl` therefore runs over SSH rather than against an
exposed API server. A conventional load-balancer ingress would have meant opening ports and then
defending them; here there is nothing listening to defend.

**One replica, stated honestly.** Cloudflare recommends two cloudflared replicas so a tunnel survives
a pod restart. A single-node cluster (§6.3) has nowhere to place the second, so ingress availability
is bounded by node availability — which is already true of the database and the ingester. A second
replica would buy nothing here except memory pressure against the §6.2 budget.

---

## 7. Architecture

```
SPTrans Olho Vivo API   (upstream, not under my control)
          |
          v
     Ingester  ────────────>  Prometheus  ──────>  Grafana + burn-rate alerts
   (Go, Deployment)             (scrapes /metrics)          |
          |                                                 v
          v                                            Alertmanager
     TimescaleDB
   (local-path PVC)
          |
          v
   Read API  ──── Cloudflare Tunnel ────>  Leaflet map (Cloudflare Pages)
```

Internal structure of the ingester:

```
poll loop (per feed) ─┐
poll loop (per feed) ─┼──> buffered channel ──> batching writer ──> COPY into Timescale
poll loop (per feed) ─┘         (backpressure boundary)

/metrics HTTP server (runs alongside)
/healthz  → asserts last successful write within N seconds
```

---

## 8. Host options and cost

| Host | Cost | Arch | Notes |
|---|---|---|---|
| Oracle A1 Always Free | $0 | arm64 | Provision at **2 OCPU / 12 GB** — the Always Free A1 allocation was halved in mid-2026 and instances above the new limit face termination from 18 Aug 2026. 200 GB block storage unchanged. |
| Hetzner CAX11 / CX22 | ~€4/mo | arm64 / amd64 | Boring, reliable, provisions instantly. |
| Owned hardware | ~R$10/mo electricity | amd64 | Requires the tunnel. Worse availability — which is *useful*, since it produces real outages to write up. |

**Known Oracle risks:**
- *Capacity.* "Out of host capacity" for A1 shapes is common and regional. Timebox attempts to one evening; if it fails, move to Hetzner. Four euros is worth not losing three days to a retry loop.
- *Idle reclamation.* Oracle reclaims Always Free compute deemed idle over a 7-day window when CPU p95, network, **and** (on A1) memory are all under 20%. All three must be true. Memory is the protection: 20% of 12 GB is 2.4 GB, and k3s + Prometheus + Timescale will exceed that. Worth monitoring rather than assuming.

**Decision (2026-08-24): Hetzner CX23 in `hel1`.** Oracle A1 was attempted first and
had no capacity for the required shape — the *Capacity* risk above, materialising
exactly as written. The timebox is what mattered: the fallback was taken the same
evening instead of turning into a multi-day retry loop. Roughly €4/month against $0
is a fair price for three days not spent refreshing a provisioning page.

Two consequences worth recording, because both contradict an assumption made earlier
in this document:

- **The host is amd64, not arm64.** CX is Intel; only the CAX line is Ampere. So the
  multi-arch build in §6.1 is not load-bearing *today* — the laptop and the server
  agree on architecture for the first time. It is kept anyway, because what it buys
  is the ability to move to Oracle or to the spare machine without a rebuild, and
  that optionality is the entire point of §6. Dropping it now would be trading the
  design's main property for a marginally faster build.
- **Every Hetzner region is far from São Paulo.** There is no South American region,
  so each poll crosses an ocean: expect a fixed ~100–200 ms floor in
  `upstream_request_duration` (§5.1). This is not a threat to the 120 s freshness SLO
  (§5.2) — it is under 0.2% of the budget — but it does change what that metric
  *means*. The panel will be measuring distance, not upstream health, so no alert may
  be hung on its absolute value; only on a change in it. `ash` (Ashburn) would roughly
  halve the floor if that ever stops being acceptable.

Layer B was built and proven locally before any of this, which is why the move cost
one evening: `kubectl apply` ran against the box with the manifests unchanged.

---

## 9. v0 scope and build order

### 9.1 What v0 includes

Steps 0–7 below. Excluded and deferred to v1: compression and retention policies, the full-fleet scale test, the GBFS second feed.

### 9.2 Definition of done

v0 is done when all five artifacts exist. If one is missing, it is not done.

1. **A live map at a public URL.** Three corridors, positions refreshing. Deliberately plain.
2. **A Grafana dashboard**, screenshot-able: current freshness, freshness p99 over the window against the 120-second target, ingest rate, upstream latency percentiles, parse failures by reason, remaining error budget as a percentage.
3. **An alert that has actually fired** — not a rule that exists, but one that triggered, notified, and was acted on. Evidence retained.
4. **A repo** containing: Go ingester, Kubernetes manifests, k3s bootstrap script, one Terraform module for the chosen host, `README.md`, `DESIGN.md`, `RUNBOOK.md`, `POSTMORTEM-001.md`.
5. **One measured number:** *"Ran continuously for N days. Measured p99 freshness of X seconds against a 120-second target, consuming Y% of the monthly error budget."*

### 9.3 The calendar constraint

Artifact 5 means **v0's definition of done includes elapsed time, not just completed work.** A 30-day p99 cannot be reported on a service that has been up three days. Roughly two weeks of continuous operation is the minimum for the number to mean anything.

**Therefore: finish building by mid-September** to have two weeks of clean data by early October. Uptime is on the critical path. This is the reason compression, the scale test, and GBFS are v1 — not because they are hard, but because they do not accumulate runtime.

### 9.4 Build order

Walking skeleton principle: wire everything end to end before making any of it good. Most of the pain is in the connections, not the features — front-load it.

**Step 0 — Python spike.** Throwaway script. Authenticate, pull positions, print raw JSON. Establish: actual update cadence, token lifetime, rate limits, which fields are ever null, how many vehicles a typical corridor has. Delete afterward.

**Findings (2026-08-22, run at São Paulo `hr=12:20`):**
- **Cadence ~45 s** (see §4.5) — drove the §4.5 / §5.2 / §4.6 / §4.3 revisions from the original 30 s assumption.
- **Auth:** `POST /Login/Autenticar?token=…` returns the text `true` and sets cookie `apiCredentials`; the session survived ≥151 s of continuous use. The ingester re-authenticates **reactively** on an auth failure, not on a fixed timer (true ceiling unprobed).
- **Rate limits:** none observed at ~1 req/5 s (no 429s, no `Retry-After`). True ceiling undocumented but far above our cadence.
- **Null fields:** `p`, `a`, `ta`, `py`, `px` were all present and non-null across **7,141 vehicles** — zero exceptions in the sample. The docs' field *types* are not authoritative, though: `p` (prefix) arrives as a JSON **string**, not the integer the docs claim, and the vehicle object also carries `sv`/`is` fields that came back null. The Go structs are typed against the live payload.
- **Empty / unknown line:** a line with no vehicles *and* a nonexistent line code both return `HTTP 200` with `{"hr":…,"vs":[]}` — never a 404. Confirms the §5.1 rationale for `positions_ingested_total`: transport-layer success ≠ semantic success.
- **In-service volume (midday):** ~7,141 vehicles across 1,914 lines; busiest single line ~28 vehicles, most trunks ~13–18. (Note: the ~15k in §4.6 is *total mapped* fleet; peak in-service is higher than midday — worth a rush-hour re-run before relying on the full-fleet arithmetic.)

*Justified exception to the walking-skeleton principle:* the upstream API is the one unknown that could invalidate the design. If positions update every two minutes, both the polling interval and the SLO threshold change. Better to learn that before building infrastructure around wrong numbers.

**Step 1 — Local skeleton, in checkpoints.** Each has a visible result in a few hours, so being stuck is detectable.

- **1a.** Go ingester, one hardcoded line, one poll, writes one row to Postgres. Both in docker-compose on the laptop.
- **1b.** Same two containers running on local k3s, with manifests. Multi-arch build configured now, not later.
- **1c.** Read API serving the latest positions.
- **1d.** Leaflet page rendering one real dot from the real API.

Do not linger in 1a. Once a row is written locally, move to k3s immediately — sitting in docker-compose for three weeks is exactly the failure the walking-skeleton principle exists to prevent.

**Step 2 — Real ingest loop.** Ticker, three corridors, exponential backoff on upstream failure, structured logging, batched writes, buffered channel with an explicit drop-or-block policy.

**Step 3 — Metrics.** The four metrics from 5.1. Prometheus deployed as a plain Deployment, scraping the ingester.

**Step 4 — SLO and dashboard.** Grafana, freshness recording rules, burn-rate alert, Alertmanager routing to somewhere actually seen.

**Step 5 — Probes.** Liveness on write recency, readiness on DB connectivity. Explicit requests and limits on every pod.

**Step 6 — Move to a host.** Pick Oracle or Hetzner or the spare machine. Write Layer A. Deploy Layer B unchanged — if it does not deploy unchanged, that is a bug in Layer B, not a reason to fork the manifests. Set up the Cloudflare Tunnel. **The clock on artifact 5 starts here.**

**Outcome (2026-08-24) — the beta is live.** `https://map.callera.com.br` (Pages) →
`https://api.callera.com.br` (Tunnel) → k3s on Hetzner → TimescaleDB. **The artifact-5 clock starts
at 23:57 UTC on 2026-08-24.** Do not rebuild the box; a replacement resets that clock to zero.

- **Layer B deployed unchanged.** The manifests that run on k3d were copied to the box and applied
  with no edits and no overlay. That was the entire bet of §6, and it is the one claim here that was
  actually tested rather than asserted.
- **Terraform reconciled to a hand-made box by import, not by rebuild.** The server already existed,
  created in the console. `prevent_destroy` then earned its place immediately: the first plan wanted
  to **destroy and recreate the running server**. The cause is worth remembering — Hetzner stores an
  SSH public key *without* its trailing comment, so a comment-bearing local copy reads as a different
  key, which forces replacement of the key and then of the server referencing it. Two fixes are kept
  in the module: match the stored key byte for byte, and `ignore_changes = [ssh_keys]`, because
  Hetzner consumes that attribute at creation and never reports it back, so an imported server
  otherwise shows an unresolvable diff forever.
- **Measured footprint:** the four pods plus k3s use ~1.05 GB of 3.7 GB. The §6.2 budget's remaining
  headroom for Prometheus and Grafana is therefore real rather than aspirational.
- **An install script is not trusted until it has run twice.** The first bootstrap exited 141 *after*
  a completely successful install: `k3s --version | head -1` under `set -o pipefail`, where the reader
  closes the pipe and k3s dies of SIGPIPE. A script run once per host lifetime hides this whole class
  of bug, which is exactly the class that surfaces during an incident at 2am. Bootstrap is now
  idempotent and verified by re-running it.

**Step 7 — Break it on purpose, then document.** Kill the pod mid-poll. Point the ingester at an invalid token. Blackhole the upstream with a NetworkPolicy. Fill the disk. Observe what fires and what stays silent; fix the alerts that stayed silent. Then write `RUNBOOK.md` and `POSTMORTEM-001.md`.

### 9.5 Priority under time pressure

Steps 0–4 give the CV line and the core story. Step 6 must happen early enough for runtime to accumulate. Step 7 is what turns "I deployed something" into "I operated something" — protect it over map polish.

### 9.6 Re-prioritisation — early public beta (2026-08-23)

**Decision:** pull step 6 (public deploy) forward, ahead of steps 3–5, to put a live link on the portfolio and — more importantly — start the runtime clock (§9.3) as early as possible. The map ships in **beta** with a visible "collecting metrics, SLO dashboard coming" banner while steps 3–4 are still being built. Step 2 is done first so the map shows a genuinely live fleet (the five lines in §11), not frozen dots.

A **bounded** frontend investment is now in scope for the beta: auto-refresh, per-line marker colour, a small legend, and the banner. This is a deliberate, limited exception to §1/§2 — the core principle stands: the SLO, alerting, runbook and postmortem remain the value, and **heavy polish plus the historical-info card stay deferred** until those artifacts exist and enough runtime has accrued for history to be meaningful. This ordering was chosen with eyes open, not by drift.

---

## 10. v1 (after v0 has accumulated runtime)

- Timescale compression and retention: raw 7 days, compress chunks older than 1 day, continuous aggregate per line per 15 minutes.
- Full-fleet scale test for one week. Measure actual compression ratio, write throughput, and what breaks. *"I measured 14× compression and 43M rows/day sustained, and found the constraint was index write amplification rather than disk"* is the goal.
- GBFS feed, to prove the pipeline handles a second feed shape.
- Nightly `pg_dump` backup to off-host storage.

---

## 11. Open questions

- Which three corridors to subset. Pick for volume and for a mix of high-frequency and low-frequency lines. Decide after step 0. **Interim (2026-08-23):** for the early public beta, tracking five consistently high-volume *individual* lines rather than full corridors — cl=402, 33361, 32975, 871, 1095 (busiest across both a midday and a midnight survey). Full three-corridor subsetting is revisited when the SLO work is underway.
- ~~Which host to land on.~~ **Closed 2026-08-24:** Hetzner CX23, after Oracle A1
  came back out of capacity. See §8.
- Whether `POSTMORTEM-001.md` documents a real unplanned incident or an induced one. Real is better; step 7 guarantees at least an induced one exists.

---

## 12. Standing rules for this repo

- No secrets in the repo or in images, ever.
- Every non-obvious decision gets a comment or a note in this file explaining *why*, not *what*.
- Layer B must never contain anything host-specific. If something host-specific is needed, it belongs in Layer A.
- Prefer boring technology. The stack is deliberately unfashionable.
- If something is not in the section 9.4 build order, it is out of scope until section 9.4 is finished.
