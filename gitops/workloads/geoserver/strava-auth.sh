#!/usr/bin/env bash
# One-time Strava OAuth setup for the strava-sync CronJob.
# Creates Secret strava-api (ns geoserver) with client creds + refresh token.
#
# Prereq: an API app at https://www.strava.com/settings/api
# ("Authorization Callback Domain" = localhost)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/repos/k8s-fun/kubeconfig}"

read -rp "Strava Client ID: " CLIENT_ID
read -rsp "Strava Client Secret: " CLIENT_SECRET; echo

cat <<EOF

Open this URL in a browser, click Authorize, then copy the "code" parameter
from the localhost URL it redirects to (the page won't load -- that's fine):

https://www.strava.com/oauth/authorize?client_id=${CLIENT_ID}&response_type=code&redirect_uri=http://localhost/exchange_token&approval_prompt=force&scope=activity:read_all

EOF
read -rp "code: " CODE

RESP=$(curl -s -X POST https://www.strava.com/oauth/token \
  -d client_id="$CLIENT_ID" -d client_secret="$CLIENT_SECRET" \
  -d code="$CODE" -d grant_type=authorization_code)

REFRESH=$(printf '%s' "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin)['refresh_token'])") || {
  echo "token exchange failed: $RESP" >&2; exit 1; }
SCOPE_CHECK=$(printf '%s' "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('athlete',{}).get('username') or 'ok')")
echo "authorized athlete: $SCOPE_CHECK"

kubectl -n geoserver create secret generic strava-api \
  --from-literal=CLIENT_ID="$CLIENT_ID" \
  --from-literal=CLIENT_SECRET="$CLIENT_SECRET" \
  --from-literal=INITIAL_REFRESH_TOKEN="$REFRESH" \
  --dry-run=client -o yaml | kubectl apply -f -

printf 'Strava API app (Secret strava-api, ns geoserver)\nclient_id: %s\nclient_secret: %s\ninitial_refresh_token: %s\nNOTE: live token rotates in postgis table strava_auth\n' \
  "$CLIENT_ID" "$CLIENT_SECRET" "$REFRESH" > "$REPO_ROOT/cluster/strava-credentials.txt"
chmod 600 "$REPO_ROOT/cluster/strava-credentials.txt"

echo "Secret created. Kick off a first sync now with:"
echo "  kubectl -n geoserver create job --from=cronjob/strava-sync strava-sync-first"
