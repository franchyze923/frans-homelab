# immich

Self-hosted photo/video backup (Immich **v3.0.1**), deployed fresh in-cluster.

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
`immich-secrets` holds `DB_PASSWORD` (alphanumeric only). It is applied
**out-of-band** from a gitignored `secret.yaml` and is intentionally NOT a git
manifest -- do not add a `secret.example.yaml` (or any Secret manifest) into
this directory: ArgoCD would apply it as the real `immich-secrets` with
placeholder values and seed Postgres with a bogus password. `secret.yaml` is
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
  DB_PASSWORD: CHANGE_ME_alphanumeric_only
  # Optional -- only needed for the FranPhotos library auto-bootstrap (below).
  # OMIT these entirely unless you set real values; placeholder/bogus creds make
  # the bootstrap Job fail instead of cleanly no-op'ing.
  # IMMICH_ADMIN_EMAIL: you@example.com
  # IMMICH_ADMIN_PASSWORD: your-real-immich-admin-password
  # IMMICH_ADMIN_NAME: Your Name        # optional display name
```

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
> inside the container use trust auth.)

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
3. **Reconciles a declared set of external libraries** (name → import paths).
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
blocks a sync. To change the library, edit `LIBRARY_NAME` / `IMPORT_PATH` in
`library-bootstrap.yaml`.

> The hook only re-runs on an ArgoCD **sync**. After a fresh install where the
> Secret already carries the admin creds, the automatic PostSync run does
> everything. If you add/rotate the admin creds *after* the app is already
> Synced, trigger one sync (e.g. `kubectl -n argocd patch application immich
> --type merge -p '{"operation":{"sync":{}}}'`) to fire it.

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
