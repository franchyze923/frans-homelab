# weight-dashboard

Flask/gunicorn app that serves Withings body-composition data at `/api/weights`
(scraped by Prometheus' `weight-exporter`) and a web UI at `/`. Migrated off the
Docker container on the GPU box.

## Image
Built from `~/repos/weight-dashboard` (Dockerfile) and pushed to
`franchyze923/weight-dashboard:latest`. To update:

```sh
cd ~/repos/weight-dashboard
docker build -t franchyze923/weight-dashboard:latest .
docker push franchyze923/weight-dashboard:latest
kubectl rollout restart deploy/weight-dashboard -n weight-dashboard
```

## Secret (applied out-of-band, NOT in git)
The Withings OAuth app credentials live in a Secret `withings-api-creds`.
`secret.yaml` is gitignored. Template:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: withings-api-creds
  namespace: weight-dashboard
type: Opaque
stringData:
  CLIENT_ID: "REPLACE_ME"
  CLIENT_SECRET: "REPLACE_ME"
```

```sh
kubectl apply -f workloads/weight-dashboard/secret.yaml
```

## OAuth token state (`tokens.json`) — NOT in git
The live OAuth tokens (`access_token` / `refresh_token` / `expires_at`) live on
the `weight-dashboard-tokens` PVC at `/data/tokens.json`. The app refreshes them
in place. Withings **rotates refresh tokens**, so never run two instances at
once. On a rebuild, re-seed `/data/tokens.json` from a recent copy, or re-auth
through the app's OAuth flow.
