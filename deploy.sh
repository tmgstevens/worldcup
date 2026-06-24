#!/usr/bin/env bash
#
# Deploy the Redpanda Connect pipeline configs in this repo to Redpanda Cloud as
# managed pipelines (create-or-update by display name). No kubectl required.
#
# Auth — pick one:
#   export RP_CLOUD_TOKEN=...                       # an existing Cloud access token, OR
#   export RP_CLIENT_ID=...  RP_CLIENT_SECRET=...   # a Cloud service account (client credentials)
#
# Target cluster data plane (defaults to this project's cluster):
#   export DATAPLANE_URL=https://<your-cluster-dataplane>.cloud.redpanda.com
#
# Usage:
#   ./deploy.sh
#
# Notes:
#   - Pipelines reference secrets as ${secrets.NAME}; those secrets must already
#     exist in Redpanda Cloud (e.g. REDPANDA_SASL_PASSWORD).
#   - The producer + backfill run fully managed. The Grafana consumer is left
#     commented out below: a managed pipeline must be able to reach the Grafana
#     endpoint in its output url, and uses ${secrets.GRAFANA_TOKEN}.
set -euo pipefail
cd "$(dirname "$0")"

DATAPLANE_URL="${DATAPLANE_URL:?set DATAPLANE_URL to your cluster data plane URL}"
AUTH_URL="${RP_AUTH_URL:-https://auth.prd.cloud.redpanda.com/oauth/token}"
AUDIENCE="${RP_AUDIENCE:-cloudv2-production.redpanda.cloud}"
API="${DATAPLANE_URL%/}/v1/redpanda-connect/pipelines"

# display_name | config file | cpu_shares | memory_shares
PIPELINES=(
  "worldcup-events|worldcup-events.yaml|0.1|400MB"
  "worldcup-backfill|worldcup-backfill.yaml|0.1|400MB"
  # "worldcup-grafana-annotations|worldcup-grafana-annotations.yaml|0.1|256MB"
)

get_token() {
  if [[ -n "${RP_CLOUD_TOKEN:-}" ]]; then printf '%s' "$RP_CLOUD_TOKEN"; return; fi
  : "${RP_CLIENT_ID:?set RP_CLOUD_TOKEN, or RP_CLIENT_ID + RP_CLIENT_SECRET}"
  : "${RP_CLIENT_SECRET:?set RP_CLIENT_SECRET}"
  curl -fsS "$AUTH_URL" -H 'Content-Type: application/json' -d @- <<JSON | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])'
{"grant_type":"client_credentials","client_id":"$RP_CLIENT_ID","client_secret":"$RP_CLIENT_SECRET","audience":"$AUDIENCE"}
JSON
}

TOKEN="$(get_token)"
AUTH=(-H "Authorization: Bearer $TOKEN")

existing_id() { # $1=display_name -> prints id or empty
  curl -fsS "${AUTH[@]}" "$API" \
    | python3 -c "import sys,json;n='$1';print(next((p['id'] for p in json.load(sys.stdin).get('pipelines',[]) if p.get('display_name')==n),''))"
}

deploy() { # $1=name $2=file $3=cpu $4=mem
  local name="$1" file="$2" cpu="$3" mem="$4" payload id
  payload="$(python3 - "$name" "$file" "$cpu" "$mem" <<'PY'
import sys,json
name,file,cpu,mem = sys.argv[1:5]
print(json.dumps({
  "display_name": name,
  "config_yaml": open(file).read(),
  "resources": {"cpu_shares": cpu, "memory_shares": mem},
}))
PY
)"
  id="$(existing_id "$name")"
  if [[ -n "$id" ]]; then
    echo "updating $name ($id)"
    curl -fsS -X PUT "${AUTH[@]}" -H 'Content-Type: application/json' "$API/$id" -d "$payload" \
      | python3 -c 'import sys,json;print("  state:",json.load(sys.stdin).get("state"))'
  else
    echo "creating $name"
    curl -fsS -X POST "${AUTH[@]}" -H 'Content-Type: application/json' "$API" -d "$payload" \
      | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  id:",d.get("id")," state:",d.get("state"))'
  fi
}

for spec in "${PIPELINES[@]}"; do
  IFS='|' read -r n f c m <<< "$spec"
  deploy "$n" "$f" "$c" "$m"
done
echo "done."
