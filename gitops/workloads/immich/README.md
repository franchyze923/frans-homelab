# immich

Self-hosted photo/video backup (Immich **v3.0.1**), deployed fresh in-cluster.

## Components
- `immich-server` — API + web UI (`:2283`)
- `immich-machine-learning` — face/object/smart-search, **CUDA** image on the Tesla P4
- `immich-postgres` — Immich's VectorChord/pgvecto-rs Postgres (required; not stock pg)
- `immich-redis` — valkey, ephemeral queues/cache

## Storage split
- **Ceph RBD** (`rook-ceph-block`, RWO): `immich-postgres` (DB), `immich-model-cache`
  (ML models), and `immich-data` (the `/data` root — thumbnails, profile, upload
  staging, in-app `/data/backups`). Small, fast, derivable.
- **NFS** (static PVs, `Retain` — survive a PVC/cluster rebuild):
  | PVC | mount | contents |
  |---|---|---|
  | `immich-library` (RWX) | `/data/library` | **original** uploaded photos/videos (`FranData/immich`) |
  | `immich-encoded-video` (RWX) | `/data/encoded-video` | transcoded videos (moved off Ceph — they were huge ×3-replicated) |
  | `immich-ext-franhomemedia` (ROX) | `/mnt/external/FranHomeMedia` | existing photos, indexed in place (read-only) |
  | `immich-ext-familyhomemedia` (ROX) | `/mnt/external/FamilyHomeMedia` | family photos, indexed in place (read-only) |
  | `immich-db-backup` (RWX) | — | nightly `pg_dumpall` target (`FranArchives/k8s-pvs/immich`) |

> All NFS PVs are **static** with `persistentVolumeReclaimPolicy: Retain` (data
> survives a PVC delete), matching the other media shares. The `nfs-client`
> dynamic provisioner was avoided — it's a single fragile pod and lands data in
> the `k8s-pvs` backup folder, neither ideal for a photo library.
>
> Because `immich-data` is **RWO Ceph**, the server is pinned to a single node
> (RWO = one node at a time). Scaling import workers across nodes would require
> moving `/data` to an RWX volume first — see the worker-scaling note if revisited.

## Secret (out-of-band, NOT in git)
`immich-secrets` holds the DB password and (optionally) the admin identity used
by the bootstrap hook. It is applied **out-of-band** from a gitignored
`secret.yaml` and is intentionally NOT a git manifest -- **do not add a
`secret.example.yaml` (or any Secret manifest) into this directory**: ArgoCD
would apply it as the real `immich-secrets` with placeholder values and seed
Postgres with a bogus password (this actually happened once). `secret.yaml` is
gitignored, so it does not come back from a repo clone -- if you lose it,
recreate it from this template:

```yaml
# workloads/immich/secret.yaml   (gitignored -- do NOT commit)
apiVersion: v1
kind: Secret
metadata:
  name: immich-secrets
  namespace: immich
type: Opaque
stringData:
  DB_PASSWORD: "CHANGE_ME_alphanumeric_only"   # quote it; bare digits parse as a number
  # Admin identity — set these to get a FULLY hands-off rebuild (the bootstrap
  # hook creates the admin account + all libraries). Omit them and the hook
  # no-ops; set them to REAL values (never placeholders, or login will fail).
  IMMICH_ADMIN_EMAIL: "you@example.com"
  IMMICH_ADMIN_PASSWORD: "your-real-immich-admin-password"   # symbols OK here
  # IMMICH_ADMIN_NAME: "Your Name"        # optional display name
```

> `DB_PASSWORD` must be **alphanumeric only** (Postgres connection-string
> parsing chokes on some symbols) and **quoted** (an unquoted all-digits value
> is rejected as a number). The admin password may contain symbols.

```sh
# paste the block above into workloads/immich/secret.yaml, set a real
# (alphanumeric-only) DB_PASSWORD, then:
kubectl apply -f workloads/immich/secret.yaml
```

> **If the `immich-postgres` PVC still has data on it** (i.e. you only lost
> the Secret, not the volume), the live database already has the *old*
> password baked in from its original `initdb` -- Postgres ignores
> `POSTGRES_PASSWORD` on every start after the first. `immich-postgres` will
> start fine either way, but `immich-server` will fail to authenticate until
> you align the DB to match the new secret:
> ```sh
> kubectl exec -it -n immich deploy/immich-postgres -- psql -U postgres -c \
>   "ALTER USER postgres WITH PASSWORD '<same password as DB_PASSWORD above>';"
> ```
> (Works without knowing the old password -- local socket connections from
> inside the container use trust auth.) **If instead you want a genuinely fresh
> DB**, don't `ALTER` — delete the `immich-postgres` PVC + pod and let ArgoCD
> recreate an empty one, which re-`initdb`s with the current secret's password.

## Fresh rebuild (end-to-end)
Deleting + recreating the app is safe and mostly hands-off. Photos on NFS
(`Retain`) survive; the Ceph PVCs (DB, thumbnails, model cache) are destroyed and
rebuilt empty.

1. **Delete** the app (prunes everything, incl. the Ceph `immich-postgres` PVC):
   ```sh
   kubectl -n argocd delete application immich
   ```
   `app-of-apps` (auto-sync + selfHeal) recreates the Application within a minute
   or two — you don't need to re-apply it. (Trying to *pause* app-of-apps doesn't
   hold; it self-reverts.)
2. **Apply your secret** once the `immich` namespace reappears:
   ```sh
   kubectl apply -f workloads/immich/secret.yaml
   ```
   Until it exists, `immich-postgres` sits in `CreateContainerConfigError` and
   waits — this is the safety net: with no Secret manifest in git, Postgres
   *cannot* init with the wrong password.
3. **That's it.** Postgres does a fresh `initdb` with your `DB_PASSWORD`,
   `immich-server` connects, and the **PostSync hook** auto-creates the admin
   account + all declared libraries and queues their scans.

If the first sync happened to time out while Postgres was waiting, nudge it:
```sh
kubectl -n argocd patch application immich --type merge -p '{"operation":{"sync":{}}}'
```

## Backups & restore
- **DB**: `immich-db-backup` CronJob (`db-backup.yaml`) runs `pg_dumpall` nightly
  at 3am to NFS (`FranArchives/k8s-pvs/immich`, off Ceph), keeps the 7 most
  recent dumps. Restore is a **manual** procedure -- steps are in the comment
  header of `db-backup.yaml` (scale `immich-server` to 0, load the dump into a
  fresh `immich-postgres`, scale back up).
- **Library** (the actual photos/videos): not backed up separately here --
  they live on the Unraid NFS share (`FranData/immich`) with `Retain` reclaim
  policy, so they survive a PVC/cluster rebuild by design; back them up at the
  NAS level (e.g. Unraid's own snapshot/backup jobs).
- Unlike jellyfin/plex/radarr/etc., there is **no init-container auto-restore**
  wired up for `immich-postgres` (those apps restore a config tarball from NFS
  automatically when their PVC comes up empty). Recovering the DB after a real
  PVC loss here means manually running the restore steps above. Ask if you'd
  like that automated similarly.

## Admin + library bootstrap (auto-created)
`library-bootstrap.yaml` is an ArgoCD **PostSync hook** Job that brings a
from-scratch install fully online with no manual UI steps. On every sync it, in
order:
1. **Creates the initial admin account** via `POST /api/auth/admin-sign-up`
   (only fires when the server has no admin yet — otherwise Immich returns
   *"already has an admin"* and the Job moves on).
2. Logs in as that admin.
3. **Sets job concurrency** (system-config) to a declared map — merged into the
   live config so everything else stays default + UI-editable:
   | job | value | job | value |
   |---|---|---|---|
   | `thumbnailGeneration` | 8 | `videoConversion` | 2 |
   | `metadataExtraction` | 8 | `faceDetection` | 1 |
   | `smartSearch` | 1 | | |

   CPU-bound jobs (thumbnails/metadata) parallelize on the 8-core server and the
   serialized `videoConversion` default (1) is lifted to 2. **GPU-bound jobs
   (`faceDetection`/`smartSearch`) are pinned to 1**: they run on the time-sliced
   Tesla P4 whose 8 GB VRAM is shared, not partitioned — concurrency >1 there
   OOMs ONNXRuntime (`BFCArena ... Failed to allocate`) and the jobs fail/retry.

   Reconciled every sync (source of truth is the `JOB_CONCURRENCY` map in
   `library-bootstrap.yaml`), so a UI change to these keys reverts on next sync —
   change the values in the manifest instead.
4. **Reconciles a declared set of external libraries** (name → import paths).
   For each it creates the library if missing, or updates its import paths to
   match the declared set, then validates the paths and triggers a scan when
   anything changed. Currently declared (edit the `reconcile_lib` calls in
   `library-bootstrap.yaml` to change — that list is the source of truth):
   | library | import paths |
   |---|---|
   | `FranPhotos` | `…/FranHomeMedia/Frans_Photos`, `…/FranHomeMedia/Road Trip to California/all_lumix_pics` |
   | `FamilyPhotos` | `…/FamilyHomeMedia/Family Photos` |
   | `ReemaPhotos` | `…/FranHomeMedia/Reema`, `…/FranHomeMedia/Reema's Family/India 2018`, `…/FranHomeMedia/Reema's Family/Scanned Family Photos` |

   **Missing/renamed paths are non-fatal** — Immich accepts them and the hook
   logs `MISSING: <path>` (via the validate endpoint) and carries on. When a
   path reappears it's already declared, so the next scan picks it up.

It's fully idempotent — safe to re-run on every sync. Identity comes from
`immich-secrets`:

| key | required | purpose |
|---|---|---|
| `IMMICH_ADMIN_EMAIL` | yes | admin login / created account |
| `IMMICH_ADMIN_PASSWORD` | yes | admin password (may contain symbols) |
| `IMMICH_ADMIN_NAME` | no | display name (defaults to the email local-part) |

**Until `EMAIL`+`PASSWORD` are present the Job no-ops** (exit 0) so it never
blocks a sync. To add/change libraries or paths, edit the `reconcile_lib` calls
at the bottom of the script in `library-bootstrap.yaml` (that list is the source
of truth — the reconciler PUTs each library to match it).

> The hook only re-runs on an ArgoCD **sync**. After a fresh install where the
> Secret already carries the admin creds, the automatic PostSync run does
> everything. If you add/rotate the admin creds *after* the app is already
> Synced, trigger one sync (e.g. `kubectl -n argocd patch application immich
> --type merge -p '{"operation":{"sync":{}}}'`) to fire it.

## ML self-healer
`ml-healer.yaml` is a CronJob (every 5 min) that restarts `immich-machine-learning`
when its GPU gets wedged. The ML service's ONNX Runtime CUDA arena grows greedily
and can consume all of the time-sliced P4's 8 GB VRAM; inference then fails with
`CUBLAS failure` / `Failed to allocate` and the pod returns HTTP 500 for every
job — but its **TCP readiness probe still passes**, so k8s never restarts it and
face-detection/OCR/smart-search jobs fail-and-retry forever.

The healer scans the ML pod's recent logs for that GPU-OOM signature and, above a
threshold (40 errors in an 8-min window), does a `rollout restart` — which resets
the arena and frees VRAM (observed ~7.6 GB → ~2.5 GB). Healthy runs are a no-op,
and a freshly restarted pod has no old errors in the window, so it can't loop. It
runs under a minimal namespaced ServiceAccount (read pods/logs, patch the ML
deployment). Tune `WINDOW`/`THRESHOLD` via the CronJob env.

> This is a safety net, not a cure — the arena still creeps. To reduce how often
> it trips: disable OCR (biggest GPU-job load), set `MACHINE_LEARNING_MODEL_TTL`
> so idle models unload, and/or use a smaller face model.

## Access
- Gateway: `immich.franpolignano.com`
- LoadBalancer: `192.168.40.201:2283` (shared `platform` IP) — use this as the
  server URL in the mobile app.

## Notes
- Machine-learning URL defaults to `http://immich-machine-learning:3003` — the
  service is named to match, so no extra config needed.
- Image versions are pinned to `v3.0.1`; bump server + ML together when upgrading
  (and check the release notes for DB image changes). The Postgres/VectorChord
  image tag is independent and only needs bumping if Immich's docs call for it.
