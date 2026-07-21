# overseerr

Request-management app (users browse/request movies+TV, Radarr/Sonarr pick
it up) at https://overseerr.franpolignano.com. Standard single-container
pattern -- Ceph RBD config + NFS backup PVC, restore-on-empty init
container, nightly (1:50am) backup CronJob, ClusterIP + HTTPRoute.

No secret needed -- first-run setup (Plex sign-in, linking Sonarr/Radarr)
happens through the web UI, not out-of-band.

## Migrated to Seerr (2026-07-21)

Overseerr and Jellyseerr merged into a single project, **Seerr**
(`ghcr.io/seerr-team/seerr`), in Feb 2026. Migrated this deployment the
same day the in-app deprecation notice appeared:

- Image: `lscr.io/linuxserver/overseerr` -> `ghcr.io/seerr-team/seerr`
- Config path: `/config` -> `/app/config` (same PVC, different mount path
  -- the official Seerr image expects `/app/config`)
- Dropped `PUID`/`PGID` env vars -- the official image runs as a fixed
  non-root `node` user (uid 1000), not the linuxserver.io PUID/PGID
  pattern. Added pod `securityContext` (`runAsUser`/`runAsGroup`/
  `fsGroup: 1000`) to replace what PUID/PGID used to handle.
- No manual data migration needed -- Seerr's own migrator ran
  automatically on first startup against the existing config
  (log-confirmed: `Overseerr to Seerr migration completed successfully`).
  Config dir was already uid-1000-owned from the old linuxserver image,
  so no chown pass was needed either.

Namespace/app name kept as `overseerr` (not renamed to `seerr`) to avoid
unnecessary churn on the hostname/bookmarks -- it's the same instance,
just running different code now.
