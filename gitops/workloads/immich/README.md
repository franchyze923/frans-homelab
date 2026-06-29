# immich

Self-hosted photo/video backup (Immich **v2.7.5**), deployed fresh in-cluster.

## Components
- `immich-server` — API + web UI (`:2283`)
- `immich-machine-learning` — face/object/smart-search, **CUDA** image on the Tesla P4
- `immich-postgres` — Immich's VectorChord/pgvecto-rs Postgres (required; not stock pg)
- `immich-redis` — valkey, ephemeral queues/cache

## Storage split
- **Ceph RBD** (`rook-ceph-block`): postgres data, ML model cache, and the immich
  `/data` root — i.e. thumbnails, encoded-video, profile, upload staging, backups.
- **NFS** (static PV, Retain): the **original** photos/videos at
  `192.168.40.116:/mnt/user/FranData/immich`, mounted at `/data/library`.

> The library uses a static NFS PV with `persistentVolumeReclaimPolicy: Retain`
> (photos survive a PVC delete), matching the other media shares. The
> `nfs-client` dynamic provisioner was avoided here — it's a single fragile pod
> and lands data in the `k8s-pvs` backup folder, neither ideal for a photo library.

## Secret (out-of-band, NOT in git)
`immich-secrets` holds `DB_PASSWORD` (alphanumeric only). `secret.yaml` is
gitignored. Apply it before the app syncs:

```sh
kubectl apply -f workloads/immich/secret.yaml
```

## Access
- Gateway: `immich.franpolignano.com`
- LoadBalancer: `192.168.40.201:2283` (shared `platform` IP) — use this as the
  server URL in the mobile app.

## Notes
- Machine-learning URL defaults to `http://immich-machine-learning:3003` — the
  service is named to match, so no extra config needed.
- Image versions are pinned to `v2.7.5`; bump server + ML together when upgrading
  (and check the release notes for DB image changes).
