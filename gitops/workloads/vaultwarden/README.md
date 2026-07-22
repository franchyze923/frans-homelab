# vaultwarden

Self-hosted Bitwarden-compatible password manager (Rust reimplementation of
the Bitwarden server). Internal-only: `vaultwarden.franpolignano.com`
resolves via the LAN Pi-hole wildcard, not public DNS, so it's unreachable
from the internet — same as every other `*.franpolignano.com` app.

## Data
`/data` (sqlite DB, attachments, RSA keys) lives on `rook-ceph-block`
(single-writer, survives node moves) with a nightly tarball backup to the
NAS, mirroring the gitea/radarr pattern. On a fresh PVC, an init container
auto-restores from that backup tarball if present.

## First-time setup
1. Visit `https://vaultwarden.franpolignano.com`, create your account
   (`SIGNUPS_ALLOWED=true` by default).
2. Edit the Deployment and flip `SIGNUPS_ALLOWED` to `"false"` (or set it via
   the admin panel), then `kubectl rollout restart` — no open signups needed
   after the first account exists.
3. Install the Bitwarden browser extension / mobile app, point it at a
   "self-hosted" server with that URL.

## Admin panel
`https://vaultwarden.franpolignano.com/admin`, gated by `ADMIN_TOKEN`.

## Secret (out-of-band, NOT in git)
`vaultwarden-secrets` carries `ADMIN_TOKEN`. Apply manually; do **not** add a
Secret manifest to this directory (ArgoCD would apply it — see the immich
incident):

```sh
kubectl create secret generic vaultwarden-secrets -n vaultwarden \
  --from-literal=ADMIN_TOKEN=<random-token>
```

Generate a token with `openssl rand -base64 48`. If it's ever lost/rotated,
just recreate the secret and restart the deployment.
