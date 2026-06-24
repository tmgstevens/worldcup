# World Cup 2026 → Redpanda → Grafana

Stream live **FIFA World Cup 2026** match events (kickoff, goals, yellow/red cards,
penalties, full-time) into Redpanda, then overlay them as **annotations** on Grafana
dashboards — so spikes in your metrics line up with what actually happened on the pitch.

All built on free data, with no paid sports API and no API key.

## Architecture

```
                ESPN (free, unofficial JSON API)
                          │  poll every 2m
        ┌─────────────────▼──────────────────────┐
        │  Redpanda Connect pipeline  (producer)  │
        │  worldcup-events.yaml                   │
        └─────────────────┬──────────────────────┘
                          │ produce
                   topic: worldcup.events  (keyed by match id)
                          │ consume
        ┌─────────────────▼──────────────────────┐
        │  Redpanda Connect pipeline  (consumer)  │
        │  → Grafana annotations                  │
        └─────────────────┬──────────────────────┘
                          ▼
                       Grafana
```

Both stages are **Redpanda Connect (RPCN)** pipelines. Historical loads use a one-shot
Connect job.

## Design decisions

### Data source: ESPN's unofficial API
We evaluated the field before landing here:

| Source | Free | Cards/penalties | Current (2026) season | Verdict |
|---|---|---|---|---|
| Sportradar | trial only | ✅ (+ VAR start/end) | ✅ | Push feed is sales-gated; trial quota tiny |
| API-Football | free tier | ✅ | ❌ free blocks season 2026 (paywall) | Needs paid plan |
| football-data.org | ✅ | ❌ cards are a paid add-on | ✅ | No cards on free |
| Community WC feeds | ✅ | ⚠️ score-level only | ✅ | No card detail |
| **ESPN site API** | ✅ | ✅ | ✅ | **Chosen** |

ESPN's `site.api.espn.com` soccer endpoints are free, need no key, cover the current
tournament, and expose per-match `keyEvents` (goals, cards, kickoff, etc.) each with a
real **`wallclock`** timestamp and stable event **`id`**.

**Caveat:** it's an *undocumented* API — no SLA, can change without notice. Fine for a
demo / internal dashboard; not something to depend on for production without a fallback.

### Redpanda Connect end to end
Both halves are declarative Connect configs — no bespoke producer/consumer code to
maintain. The producer makes two HTTP calls (scoreboard → per-match summary), runs a few
Bloblang mappings, and writes to Redpanda. The consumer reads the topic and POSTs Grafana
annotations. Two configs, no glue code.

### Backfill as a one-shot job
Historical loads run as a one-shot Connect **job** over a date range, kept separate from
the always-on pipelines so they can be run and torn down independently without touching
the live flow.

### Annotation time = event `wallclock`
Annotations are stamped with each event's real `wallclock`, not ingest time, so backfilled
/ historical events land at the correct moment on the dashboard.

### Tag-based annotations
Annotations carry tags `["worldcup", <kind>, <match>]`. Any dashboard with a single
dashboard-level annotation query filtered by tag `worldcup` shows them across all
time-series panels — no per-panel wiring. (Remember to raise the annotation query's
**Limit** above its default of 100.)

### Dedup
The live producer re-reads the full match timeline each poll, so it dedups on
`event_id + keyEvent id` to emit each real-world event exactly once.

## Event schema (`worldcup.events`)

JSON, keyed by `event_id` (match id):

| field | meaning |
|---|---|
| `event_id` | ESPN match id |
| `match` | `"Home vs Away"` (ESPN names matches `"Away at Home"`; rewritten) |
| `kind` | `match_start` \| `goal` \| `yellow_card` \| `red_card` \| `penalty` \| `match_end` |
| `type` | raw ESPN event type (e.g. `Goal - Header`) |
| `minute` | match clock (e.g. `67'`) |
| `wallclock` | real event time (ISO 8601) |
| `text` | human-readable description |
| `team_id`, `short`, `kickoff`, `ke_id` | supporting context |

## Files

| File | Role |
|---|---|
| `worldcup-events.yaml` | **Live producer** — Redpanda Connect pipeline, ESPN → `worldcup.events` |
| `worldcup-backfill.yaml` | One-shot backfill pipeline (single date) |
| `worldcup-grafana-annotations.yaml` | **Consumer** pipeline — `worldcup.events` → Grafana annotations |
| `k8s-worldcup-annotations.yaml` | Consumer pipeline as a Kubernetes deployment |
| `k8s-worldcup-backfill-job.yaml` | Backfill as a one-shot Kubernetes job (date range → events) |
| `deploy.sh` | Push the Connect configs to Redpanda Cloud as managed pipelines |

## Deploying

### To Redpanda Cloud (managed pipelines)
`deploy.sh` pushes each Connect config to Redpanda Cloud as a managed pipeline
(create-or-update by name) via the Data Plane API — no kubectl.

```bash
export RP_CLIENT_ID=...  RP_CLIENT_SECRET=...        # a Cloud service account
export DATAPLANE_URL=https://<your-cluster-dataplane>
./deploy.sh
```

Secrets referenced as `${secrets.*}` (e.g. `REDPANDA_SASL_PASSWORD`) must already exist
in Redpanda Cloud. The Grafana consumer is left commented out in `deploy.sh`: a managed
pipeline must be able to reach the Grafana endpoint set in its output `url`.

### Kubernetes (alternative)
```bash
kubectl apply -f k8s-worldcup-annotations.yaml
kubectl apply -f k8s-worldcup-backfill-job.yaml
kubectl logs -n worldcup job/worldcup-backfill -f
kubectl delete -f k8s-worldcup-backfill-job.yaml   # cleanup when done
```

**To see annotations:** add a dashboard annotation query (data source `-- Grafana --`,
filter by tag `worldcup`, **Limit 1000**), and set the time range to cover the match days.

## Operational notes & caveats
- **Secrets:** the committed manifests use **placeholder** secret values. Populate them
  locally; never commit real credentials. Rotate the Grafana token if it leaks.
- **Unofficial API:** ESPN endpoints can change/break without notice.
- **Token lifetime:** if the Grafana service-account token is rotated, update the
  `worldcup-secrets` Secret and restart the consumer.
- **ACLs:** the SASL user needs WRITE on `worldcup.events` (producer) and READ on the
  topic + the `grafana-annotations` consumer group (consumer).
