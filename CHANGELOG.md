# Changelog

All notable changes to the homelab are recorded here — both **cluster**
(provisioning, nodes, storage) and **GitOps** (apps). Newest first. Going
forward, every change gets an entry here.

## 2026-06-29

### Hardware inventory: audited all 4 physical hosts, uniform README table
SSH'd into every bare-metal box and refreshed the README **Physical hosts**
table with verified CPU / RAM / OS / storage (physical hardware only, VMs split
into their own table):
- `pve` (`.10`) — Dell R720, 2× Xeon E5-2660 v2 (20c/40t), 192 GB DDR3, Proxmox VE 9.2.3.
- `fran` (`.9`) — Gigabyte B450M, Ryzen 5 3600 (6c/12t), 40 GB DDR4, Proxmox VE 9.1.7.
- `UnraidBackup` (`.116`) — Dell EMC Avamar datastore (Intel S2600GZ board), Xeon E5-2603 (4c/4t), 64 GB DDR3, Unraid 7.3.1.
- `truenas` (`.240`) — **second Dell R720**, 2× Xeon E5-2640 (12c/24t), ~110 GiB DDR3,
  TrueNAS SCALE 25.10.3.1, 5× 5 TB Seagate + 2× SSD (ZFS). (Inventoried as the
  unprivileged `fran` user via `/sys` DMI — no root, so DIMM layout not enumerated.)

### Consolidated into a single repo (`frans-homelab`)
Merged the two repos that ran the homelab into one monorepo, **preserving full
git history** from both:
- `k8s-fun` → [`cluster/`](cluster/) — Terraform + Ansible cluster provisioning.
- `app-of-apps` → [`gitops/`](gitops/) — Argo CD app-of-apps.

Rewired GitOps for the new layout: all 29 in-repo Argo CD `Application`s now
point at `frans-homelab.git` with `gitops/`-prefixed paths (root app watches
`gitops/apps`); the external `nfs-provisioner` chart was left untouched. The
cluster bootstrap (`config.yml.example`, `ansible/argocd.yml`) now defaults to
this repo + `gitops/apps`. **Cut Argo CD over live** — all 30 Applications
re-reconciled to the new repo `Synced`/`Healthy` with no manifest changes. The
old `k8s-fun` and `app-of-apps` repos are now **archived** (read-only). Added a
top-level `README.md` (hardware, network, deploy + GitOps guides) and promoted
this changelog to the repo root.

### New node: second Proxmox host + Ryzen worker (`ubuntu-26-desktop-node`)
Added a **second, standalone Proxmox VE 9.1 host** (Gigabyte B450M / **AMD Ryzen 5
3600**, 6c/12t Zen2, 39 GiB) at `192.168.40.9` — the first time the cluster spans
more than the single R720. Stood up **VM 100 `ubuntu-26-desktop-node`** on it
(8 vCPU / 16 GiB / 100 GiB, Ubuntu 26.04 cloud image, IP `192.168.40.75`) which
doubles as an **XFCE desktop** and a **kubeadm worker** (v1.35.6, containerd
2.2.2, Cilium). It has the **fastest per-core CPU** in the cluster (Zen2 vs. the
2013 Xeons), so it's now the preferred home for CPU-bound workloads.

- **Unattended provision:** Ubuntu installed from the **cloud image via Proxmox
  cloud-init** (SSH keys + DHCP, no installer TUI), then worker prep mirrors the
  existing 26.04 node (`mac-m1-worker`): swap/zram off, `rbd`/`br_netfilter`/
  `overlay` modules, `nfs-common`, native containerd with `SystemdCgroup=true`,
  `kube*` pinned to **1.35.6** from `pkgs.k8s.io` v1.35.
- ⚠️ **BIOS gotcha:** the board ships with **SVM (AMD-V) disabled** even though the
  `svm` CPU flag shows (`SVM disabled by BIOS in MSR_VM_CR`) — had to enable
  *SVM Mode* in BIOS or `kvm_amd` won't load and no VM starts.
- **DVD passthrough:** the host's SATA optical drive is passed into the VM
  (`scsi2`, read-only) for ripping/reading discs (first use: copied a 129-photo
  data CD to `FranData/CD-Archives/`).
- **AMD Radeon RX 570 4 GB** discrete GPU is present but **host-owned** (`amdgpu`
  bound, not passed through). Candidate for VA-API transcoding (Plex/Jellyfin/
  Frigate) later; not an ML target (ROCm dropped Polaris).
- **Not in Git** (like the rest of the cluster's kubeadm membership / Proxmox /
  Rook config) — documented in the README **Cluster** section instead.

### Immich: prefer the new Ryzen node (test placement)
Repointed `immich-server`'s soft node-affinity from `mac-m1-worker` to
`ubuntu-26-desktop-node` (fastest cores, on its own host) to test import
performance — still **preferred** (not hard-pinned), and **ML stays GPU-pinned**
on the Tesla P4. The RWO Ceph volume re-attached cleanly on the new node (Ceph
CSI plugin already runs there); `Recreate` strategy avoided a Multi-Attach.

## 2026-06-27

### Immich availability: stop the M1 node from taking it down overnight
Two mornings in a row Immich was broken — immich-server stuck (one pod
Terminating, one Pending). Root cause: the **M1 node is a UTM VM on the Mac**, and
**macOS was sleeping overnight**, which suspended the VM → node `NotReady` →
immich-server (hard-pinned to it, with an RWO Ceph volume) couldn't terminate or
reschedule. Confirmed via `pmset -g log` (hourly `darkwake` events = the Mac was
sleeping despite the Energy-settings checkbox).

- **Mac fix (out-of-band):** `sudo pmset -a disablesleep 1` + `sleep 0` +
  `powernap 0` — the real always-on switch (the GUI toggle wasn't holding). Plus
  auto-start the UTM VM so it self-recovers.
- **Cluster fix (in Git):** immich-server changed from a **hard
  `nodeSelector: mac-m1-worker`** (M1-only → hung when the M1 was down) to a
  **soft node-affinity preference** (weight 100 for the M1) + faster
  `unreachable`/`not-ready` eviction tolerations (60s vs 300s). It now **prefers**
  the M1 but **fails over to an amd64 node** if the M1 is `NotReady` instead of
  hanging. (Caveat: the RWO Ceph volume must force-detach from the dead node
  first — ~6 min, k8s-enforced — so failover is automatic but not instant, and it
  doesn't auto-move back to the M1 on recovery.)

### Immich database backups → NFS (disaster-safe)
Immich's built-in nightly DB dump goes to `/data/backups` — but that's on the
**same Ceph volume as the live data**, so a cluster/Ceph loss takes both (a copy,
not a backup). Added `workloads/immich/db-backup.yaml`:

- **`immich-db-backup` CronJob** (daily 3am) runs Immich's documented
  `pg_dumpall` (using the matching VectorChord postgres image) **straight to NFS**
  (`FranData/FranArchives/k8s-pvs/immich`), keeps the last 7, `pipefail` so it
  truly fails on error. Connects to the postgres service (no RWO mount conflict
  with the live pod). Tested: a manual run produced a ~716 MB dump on the NAS.
- **Restore procedure documented inline** (incl. the pgvecto-rs `search_path`
  `sed` fix). Now the DB (faces, embeddings, metadata) survives a cluster rebuild.
- Still uncovered (separate 3-2-1 concern): the **photo originals** live only on
  the NAS — a NAS failure loses them; no off-NAS copy yet.

## 2026-06-26

### Overhauled the config-backup jobs (all apps)
The nightly backup CronJobs (plex, jellyfin, radarr, sonarr, sabnzbd, metube,
heimdall, keycloak, grafana, tautulli, elasticsearch) were reworked:

- **tar+gzip to a single `backup.tar.gz`** instead of `cp -r` of thousands of
  small files — far faster over NFS (Plex went from a ~56-min per-file copy to
  one stream) and compressed. Restore untars it, with a **legacy fallback** to
  the old loose-file copy so a disaster-restore still works during the switch.
- **Logs the destination** each run, e.g. `--> backed up to:
  192.168.40.116:/mnt/user/FranData/FranArchives/k8s-pvs/<app>/backup.tar.gz`.
- **Real failure detection** — backup containers switched to `debian` (GNU tar)
  so the job actually **fails** on tar exit ≥2 (NFS down, disk full) while
  tolerating exit 1 (live DB changing mid-read). The old `cp ... | tail -5`
  masked failures behind a fake "Completed". Restore initContainers stay busybox.
- **elasticsearch backup suspended** (`suspend: true`) — not needed.

### Immich operational hardening
- **OCR disabled** — the P4's 8 GB VRAM can't hold face + CLIP + OCR; OCR jobs
  failed in a retry loop (ONNX `BFCArena` OOM) and the allocator held VRAM even
  after, starving face detection. A ML-pod restart clears a stuck arena.
- **immich-server memory limit 3→4 Gi** — OOMKilled on the 6 GB M1 VM under a
  heavy import + software transcode + OCR load.
- **Added immich to `nfs-mount-healer`** — its NFS mounts (library,
  encoded-video, external libraries) now auto-recover from stale Unraid handles
  like the other media apps (confirmed working — it caught a stale handle and
  restarted immich within minutes instead of letting it get stuck).

### Tackled the recurring Unraid NFS stale-handle issue at the source
Root-caused the long-running `Stale file handle` problem (see the
unraid-nfs-stale-handles memory): `/mnt/user` is **shfs (FUSE)**, which gives out
unstable NFS file handles, and the **mover** shuffling files cache→array is the
main trigger. Confirmed `immich-encoded-video` was split across cache *and*
disk2 — proof the mover was actively churning Immich's transcodes.

- **Fix applied:** set the `FranData` share to **array-only** (`shareUseCache="no"`)
  so new writes skip the cache and the mover stops moving files → kills the
  dominant stale trigger. Existing ~24 GB on cache stays put (stable) until the
  next mover sweep relocates it once.
- Mitigation, not a cure — shfs can still rarely recycle an inode; the healer
  remains the safety net. True zero-stale fix is SMB (no file-handle concept).
- Documented the full NAS drive/share layout in the README.

## 2026-06-25

### Added an M1 Mac Mini as an arm64 cluster node
Joined an M1 Mac (Ubuntu 26.04 **arm64** VM, via UTM, bridged networking) as a
worker — the cluster is now **mixed-architecture** (4× amd64 on the R720/gpu-box
+ 1× arm64). The node is **manually managed** (kubeadm join, not in Git); the
README out-of-band section documents the prep.

- Tainted `arch=arm64:NoSchedule` to reserve it for deliberate placement.
- **Out-of-band gotchas** (all in README): rook CSI plugins need an arm64
  toleration (`CSI_PLUGIN_TOLERATIONS`) or no Ceph volumes mount there; the node
  needs the `rbd` kernel module (`/etc/modules-load.d/rbd.conf`) and `nfs-common`;
  and swap must be disabled **persistently** — on 26.04 that means masking zram,
  not just editing fstab, or the kubelet won't start after a reboot.
- Validated it's reboot-proof: node, swap, Ceph RBD, NFS, and pods all
  auto-recover (~3–4 min, gated by CSI driver re-registration).

### Moved immich-server onto the M1 (arm64)
Pinned `immich-server` to the M1 (`nodeSelector: mac-m1-worker` + arm64
toleration), sized for the VM (CPU limit 5, 3Gi). It runs the **native arm64**
Immich image with full Ceph RBD + NFS access. `immich-machine-learning` stays on
the P4 GPU node (CUDA), Postgres/redis on amd64.

- Benchmarked (libvips thumbnails): the M1 at 6 cores ≈ **38 thumbs/s** vs the
  R720 worker at 12 cores ≈ **29** — ~6× faster per core, and wins aggregate
  despite half the cores. (Bumped the M1 VM 4→6 cores; past 6 hits its weaker
  efficiency cores, diminishing returns.)

### Immich: FamilyHomeMedia library, OCR off, resource tuning
- Added a read-only NFS external library for `/mnt/user/FranData/FamilyHomeMedia`
  (mounted at `/mnt/external/FamilyHomeMedia`; `Family Photos` = ~50,940 assets).
- **Disabled the OCR ML job** — the P4's 8 GB VRAM can't hold face + CLIP + OCR
  at once (ONNX/CUBLAS OOM, face detection failing); face + smart search run
  clean without it. (Re-enable later as a separate pass if wanted.)
- Tuned `immich-machine-learning` (CPU 2→6) and `immich-server` CPU during the
  import; worker-1 VM bumped 8→12 cores on the R720 before the move to the M1.

### Misc (out-of-band)
- Labeled the M1 node's role: `node-role.kubernetes.io/m1worker` (cosmetic, not
  in Git — re-apply on rebuild).
- **Ceph dashboard password gotcha:** rook reverts password changes made in the
  dashboard UI — it enforces whatever is in the `rook-ceph-dashboard-password`
  secret. To change it durably: update the secret **and** apply it live
  (`ceph dashboard ac-user-set-password admin -i <file>`), don't use the UI.

## 2026-06-24

### Exposed the Rook-Ceph dashboard
`apps/ceph-dashboard.yaml` + `workloads/ceph-dashboard/` — an `HTTPRoute` putting
the mgr dashboard at `ceph.franpolignano.com` (cluster health, OSDs, pools, PGs,
capacity, RBD images, throughput graphs). Dashboard SSL disabled out-of-band so
the gateway terminates TLS and proxies HTTP to `rook-ceph-mgr-dashboard:7000`.

### Rearchitected Ceph storage (6→3 OSDs, size 3→2, 100→150 GB)
After a disk-full outage (see below), reworked Ceph to be simpler, predictable,
and not overcommitted. Rook-ceph is **manually managed** (not in Git) — see the
README out-of-band section.

- **6 OSDs → 3** (one per node, all on the NVMe `speedy-nvme-drive`). Drained +
  purged the extra OSD per host one at a time (`ceph osd out` → wait clean →
  scale OSD deploy to 0 → `ceph osd purge` → delete the rook deploy → delete the
  Proxmox disk; `useAllDevices:true` means the disk must be removed or the
  operator recreates the OSD). Also freed `local-lvm` (worker-2's OSD had been
  moved there during the outage).
- **OSD disks 100 → 150 GB** (`qm disk resize` live, then restart the OSD pod —
  rook's `expand-bluefs` init grows BlueStore).
- **Pool replication size 3 → 2**, `min_size 1` → usable Ceph went ~150 → ~210
  GiB. Each node now has exactly **1 OS disk + 1 OSD disk**.
- **⚠️ Device-path reboot gotcha:** removing each node's old OSD disk left a gap
  in the SCSI ordering, so on the next reboot the surviving OSD disk shifted
  `/dev/sdc → /dev/sdb`, but the rook OSD deployments had `/dev/sdc` hardcoded →
  OSDs couldn't find their disk → cluster down. Fix: `kubectl -n rook-ceph set
  env deploy/rook-ceph-osd-<id> ROOK_BLOCK_PATH=/dev/sdb` + restart each pod. Now
  stable (paths match), but adding/removing a node disk could shift them again.

### Moved Immich transcodes off Ceph + fixed the disk-full outage
A Proxmox datastore (`speedy-nvme-drive` LVM-thin pool) filled to ~90% — Immich's
`encoded-video` (transcodes) had grown to 58 GB ×3 replication on Ceph and, with
the pool overcommitted, paused all VMs overnight (clock skew → Ceph broke; see
the proxmox-pause-clock-skew memory).

- **`encoded-video` → NFS** at `/mnt/user/FranData/immich-encoded-video` (static
  RWX PV) so Ceph no longer grows with transcodes.
- Enabled BlueStore discard (`bdev_enable_discard`) + `fstrim` so freed space
  actually returns to the thin pool. `speedy-nvme-drive` 90% → ~59%.

## 2026-06-23

### Deployed Immich (v2.7.5) as a cluster app
Fresh in-cluster Immich (photo/video backup) — `apps/immich.yaml` +
`workloads/immich/`. Four components: `immich-server`, `immich-machine-learning`
(CUDA image on the time-sliced P4), VectorChord Postgres, and valkey.

- **Storage split:** Ceph RBD for Postgres data, ML model cache, and the `/data`
  root (thumbnails, encoded-video, profile, upload staging); a **static NFS PV
  (Retain)** at `/mnt/user/FranData/immich` for the original photos
  (`/data/library`). Ceph only had ~169 GB free, so originals must live on NFS.
- DB password via out-of-band Secret `immich-secrets` (`secret.yaml` gitignored).
- Exposed at `immich.franpolignano.com` and the shared LB `192.168.40.201:2283`.
- Gotcha hit along the way: the `nfs-client` dynamic provisioner pod was stuck
  on a stale NFS mount — force-restarted it, and switched Immich's library to a
  static PV instead (more robust + cleaner path).

### Removed headlamp
Deleted the `headlamp` app (k8s dashboard) — no longer used. Removed
`apps/headlamp.yaml` + `workloads/headlamp/`; Argo pruned the Deployment,
Service, HTTPRoute (`headlamp.franpolignano.com`), and namespace.

### Exposed weight-dashboard on the shared LoadBalancer IP
weight-dashboard Service is now `LoadBalancer` on the shared `platform` IP
(`192.168.40.201:5000`) via the sharing-key — reachable directly as well as
through the gateway hostname and in-cluster.

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
