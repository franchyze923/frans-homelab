# Changelog

All notable changes to the homelab GitOps config are recorded here. Newest first.

## 2026-06-23

### Migrated Radarr + Sonarr config from Unraid into the cluster
Restored the working Radarr/Sonarr configs off the Unraid box (192.168.40.116)
into the cluster instances via each app's native backup/restore API (upload the
System → Backup zip to `/api/v3/system/backup/restore/upload`, then restart).

- Radarr: 476 movies, root folder `/movies` (matches cluster mount).
- Sonarr: 122 series, root folder `/tv` (matches cluster mount).
- Indexers, download clients, quality profiles, and history all carried over;
  API keys are now the original Unraid keys (restored config.xml).
- Backup zips contain API keys + DBs and are gitignored (`*_backup_*.zip`).
- Known follow-up: download-client still points at Unraid SAB
  (`192.168.40.116:8080`), whose completed dir (`/FranMedia/misc/sab_nzb/complete`)
  the cluster pods can't see. Resolved when SAB is migrated — align cluster SAB's
  completed dir to `/downloads` and repoint Radarr/Sonarr at the `sabnzbd` service.

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
