# networth

Net-worth tracker: yearly snapshots of every account (assets + liabilities),
editable through the year, frozen at year-end for year-over-year comparison.
Flask/gunicorn + SQLite on a Ceph RBD PVC. UI at `/`, JSON export/import for
backups.

Reachable at https://networth.franpolignano.com (via main-gateway).

## Image

Built from `~/repos/networth-tracker` (Dockerfile) and pushed to
`franchyze923/networth-tracker:latest`. To update:

```sh
cd ~/repos/networth-tracker
podman build -t franchyze923/networth-tracker:latest .
podman push franchyze923/networth-tracker:latest
kubectl rollout restart deploy/networth -n networth
```

## Seed data (applied out-of-band, NOT in git)

The finance numbers are personal — they are **never** committed here or baked
into the (public) image. The app imports `/seed/seed.json` from the
`networth-seed` Secret once, only when its database is empty. `secret.yaml` is
gitignored; regenerate it from the (also gitignored) seed file in the app repo:

```sh
kubectl create secret generic networth-seed -n networth \
  --from-file=seed.json=~/repos/networth-tracker/seed.json \
  --dry-run=client -o yaml > secret.yaml
kubectl apply -f secret.yaml
```

The Secret mount is `optional: true`, so the pod runs fine without it.

## Backups

All state is the SQLite file on the `networth-data` PVC. The UI's **Export**
button downloads the full dataset as JSON; **Import** restores it (replace-all).
On a rebuild, either re-import an export or re-apply the seed Secret.
