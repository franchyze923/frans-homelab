# Changelog

All notable changes to the homelab GitOps config are recorded here. Newest first.

## 2026-06-23

### Migrated weight-dashboard from Docker to a cluster app
Moved the Withings body-composition dashboard (serves `/api/weights` for the
Prometheus `weight-exporter`) off the Docker container on the GPU box into the
cluster as `weight-dashboard`.

- Pushed the running image to `franchyze923/weight-dashboard:latest` (built from
  `~/repos/weight-dashboard`).
- Ceph RBD PVC holds the OAuth `tokens.json` (refreshed in place). Withings
  rotates refresh tokens, so the Docker copy was stopped first, then its final
  `tokens.json` seeded into the PVC — no re-auth, no two-writer conflict.
- Withings `CLIENT_ID`/`CLIENT_SECRET` via out-of-band Secret `withings-api-creds`
  (`secret.yaml` gitignored). Gateway route `weight-dashboard.franpolignano.com`
  + hourly ping CronJob to keep tokens fresh.
- Repointed `weight-exporter` `WEIGHT_API_URL` from `192.168.40.13:5000` to the
  in-cluster service; metrics confirmed flowing. Docker container stopped/disabled.

### Added nfs-mount-healer (auto-recovery for stale Unraid NFS mounts)
Recurring problem: all NFS exports come from Unraid `/mnt/user` (shfs FUSE),
which hands out unstable NFS file handles — clients periodically get ESTALE
("Stale file handle") until remounted, and it had to be fixed by hand. The
Unraid-side knob (`fuse_remember`) isn't exposed in this Unraid version, so the
fix lives in-cluster.

- New app `nfs-mount-healer`: a CronJob (every 3 min) that execs `ls` against
  each media pod's NFS mount and, on a confirmed `Stale file handle`, deletes
  the pod so the kubelet re-mounts it fresh. (A liveness probe can't do this —
  a container restart doesn't re-mount; only pod recreation does.)
- Only acts on confirmed ESTALE (transient/other errors are logged, not
  restarted) so live Plex/Jellyfin streams aren't interrupted needlessly.
- Watches plex, jellyfin, radarr, sonarr, sabnzbd, metube; scoped RBAC
  (exec + delete) via per-namespace RoleBindings.
- Caught and healed a stale Plex `/media` mount on its first run.

### Migrated Radarr + Sonarr config from Unraid into the cluster
Restored the working Radarr/Sonarr configs off the Unraid box (192.168.40.116)
into the cluster instances via each app's native backup/restore API (upload the
System → Backup zip to `/api/v3/system/backup/restore/upload`, then restart).

- Radarr: 476 movies, root folder `/movies` (matches cluster mount).
- Sonarr: 122 series, root folder `/tv` (matches cluster mount).
- Indexers, download clients, quality profiles, and history all carried over;
  API keys are now the original Unraid keys (restored config.xml).
- Backup zips contain API keys + DBs and are gitignored (`*_backup_*.zip`).
- Exposed both on the shared `platform` LoadBalancer IP: `192.168.40.201:7878`
  (Radarr) / `:8989` (Sonarr), plus the existing gateway hostnames.

### Migrated SABnzbd config from Unraid into the cluster
Loaded the Unraid `sabnzbd.ini` (Newshosting server, categories, API keys) into
the cluster SAB. SAB has no restore API, so the file was swapped on the config
PVC via an in-pod s6 stop → overwrite → start (avoids the SQLite/Argo issues).

- `complete_dir` changed to `/downloads` so it matches what Radarr/Sonarr mount
  (`FranMedia/Completed_dls`); `download_dir=/downloads/incomplete`.
- `host_whitelist` extended with `sabnzbd`, `sabnzbd.sabnzbd.svc.cluster.local`,
  and `sabnzbd.franpolignano.com` (else SAB rejects the new hostnames).
- Repointed Radarr/Sonarr download client to
  `sabnzbd.sabnzbd.svc.cluster.local:8080` (cross-namespace FQDN, not the bare
  name) — connection tests pass and both apps are health-clean.
- Exposed SAB on the shared `platform` LB at `192.168.40.201:8080`; to free that
  port, `python-demo` moved to `192.168.40.201:8088` (still a LoadBalancer).
- `sabconfig.ini` is gitignored (Usenet credentials + API keys).

## 2026-06-22

### Moved Frigate config into a ConfigMap + Secret (GitOps-reproducible)
Frigate's `config.yaml` is now managed in git as a ConfigMap
(`workloads/frigate/configmap.yaml`), mounted over `/config/config.yaml` via
subPath. The camera password is no longer in the config file — it's referenced
as `{FRIGATE_REOLINK_PASSWORD}` and injected from a Secret.

- The Secret (`frigate-secrets`) is applied **out-of-band**, not via ArgoCD:
  edit `workloads/frigate/secret.yaml` (gitignored) and `kubectl apply` it.
  See `workloads/frigate/README.md` for the template — it's documented in
  markdown (not a `.yaml`) on purpose, so ArgoCD doesn't apply it and clobber
  the real Secret.
- Only the SQLite DB and recordings remain on hostPath now; the config itself
  is reproducible from the repo.
- Editing config via the Frigate UI no longer persists (read-only mount) —
  change `configmap.yaml` and re-sync; a pod restart picks it up.

### Migrated Frigate from Docker to an ArgoCD app
Moved Frigate (NVR) off the native Docker container on the GPU box and into the
cluster as a managed ArgoCD application (`apps/frigate.yaml`, `workloads/frigate/frigate.yaml`).

- Runs `frigate:stable-tensorrt`, pinned to the GPU node and requesting a
  time-sliced `nvidia.com/gpu` slice — now the 3rd GPU consumer sharing the
  Tesla P4 alongside ollama and Plex.
- Reuses the existing on-disk data in place via `hostPath`
  (`/home/fran/frigate/{config,storage}`), so the config, SQLite DB, and ~105 GB
  of recordings carried over with zero migration.
- Web UI exposed on the shared gateway at `frigate.franpolignano.com`.
- GPU verified: ONNX (yolox) detection + NVDEC decode running on the P4.
- The native Docker container was stopped and disabled as part of cutover.

> [!IMPORTANT]
> **Config is in git; data is not.** As of the ConfigMap/Secret change above,
> `config.yaml` is reproducible from the repo. What still lives only on the GPU
> box (`ubuntu24-gpu-box`, 192.168.40.13) via `hostPath`:
> - **Database (SQLite):** `/home/fran/frigate/config/frigate.db`
> - **Model cache:** `/home/fran/frigate/config/model_cache/`
> - **Recordings (~105 GB):** `/home/fran/frigate/storage`
>
> Also not in git: the `frigate-secrets` Secret (camera password), applied
> out-of-band from `secret.yaml`. If you rebuild the GPU node, **back up
> `/home/fran/frigate/` and re-apply the Secret first** — otherwise you lose
> history/recordings (the config + manifests redeploy from the repo). The pod is
> pinned to this node (`nodeSelector: gpu=true`) because the data is local to it.

Known follow-up: Frigate's recordings keep the GPU node's disk near the
disk-pressure threshold (k8s evicts/taints under disk pressure, unlike Docker).
Mitigate later by trimming retention, moving recordings to NFS, or growing the VM disk.
