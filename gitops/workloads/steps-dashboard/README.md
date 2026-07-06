# steps-dashboard

Flask/gunicorn app that pulls daily step counts from Garmin Connect (unofficial
API via the `garminconnect` library), caches them in SQLite on the
`steps-dashboard-data` PVC, and serves a dashboard at
`steps.franpolignano.com` (`/api/steps` JSON, `/metrics` for Prometheus).

A background thread syncs hourly; the first run backfills a year of history.

## Image

Built from `~/repos/steps-dashboard` (Dockerfile) and pushed to
`franchyze923/steps-dashboard:latest`. To update:

```sh
cd ~/repos/steps-dashboard
podman build -t franchyze923/steps-dashboard:latest .
podman push franchyze923/steps-dashboard:latest
kubectl rollout restart deploy/steps-dashboard -n steps-dashboard
```

## Secret (applied out-of-band, NOT in git)

Garmin Connect credentials live in a Secret `garmin-creds`. `secret.yaml` is
gitignored. Template:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: garmin-creds
  namespace: steps-dashboard
type: Opaque
stringData:
  GARMIN_EMAIL: "REPLACE_ME"
  GARMIN_PASSWORD: "REPLACE_ME"
```

```sh
kubectl apply -f workloads/steps-dashboard/secret.yaml
```

The Secret is only read when the token store is missing/expired — after the
first successful login the app runs off tokens on the PVC (below).

## Garmin OAuth token state — NOT in git

Live OAuth tokens (valid ~1 year, refreshed in place) live on the
`steps-dashboard-data` PVC at `/data/garmin-tokens/`. Never run two instances
at once (Deployment uses `Recreate`).

**MFA:** the in-cluster login can't answer an MFA prompt. If the account has
MFA enabled, mint tokens locally with `login_local.py` in the app repo and
`kubectl cp` the `garmin-tokens/` dir to `/data/` in the pod — instructions in
that file's docstring. On a rebuild, either re-seed the token dir or just let
the app re-login from the Secret (non-MFA) and re-backfill.
