# Homelab — Argo CD App-of-Apps

GitOps configuration for my homelab Kubernetes cluster. Everything that runs on
the cluster is declared here; **Argo CD** continuously syncs this repo to the
cluster, so `git push` is the deploy mechanism.

See [CHANGELOG.md](../CHANGELOG.md) (repo root) for a running history of changes.

## How it works

A single root Application (`apps/app-of-apps.yaml`) watches the `apps/` folder
(`directory.recurse: true`). Each `apps/<name>.yaml` is a child Argo CD
`Application` that points at the matching `workloads/<name>/` directory. All apps
run with **automated sync, prune, and self-heal**, so the cluster is kept in
lock-step with `main`.

```
apps/<name>.yaml          # Argo CD Application  ->  points at...
workloads/<name>/*.yaml   # the actual k8s manifests (Deployment, Service, etc.)
```

To deploy: edit/add manifests, commit, push. Argo syncs within a few minutes
(or `kubectl annotate app -n argocd <name> argocd.argoproj.io/refresh=hard --overwrite`).

## Cluster

- **kubeadm** cluster: 1 control-plane + 2 workers (Rocky Linux) + 1 GPU node
  (`ubuntu24-gpu-box`, Ubuntu, Tesla P4) + 1 arm64 node (`mac-m1-worker`, an M1
  Mac VM) + 1 Ryzen node (`ubuntu-26-desktop-node`, Ubuntu 26.04, doubles as an
  XFCE desktop). **Mixed-architecture** (5× amd64 + 1× arm64).
- **Proxmox hosts (2):**
  - **Dell R720**, dual Xeon E5-2660 v2 (20c/40t) — runs the control-plane + 2
    Rocky workers + the M1 arm64 VM off a single NVMe (`speedy-nvme-drive`).
  - **Gigabyte B450M / AMD Ryzen 5 3600** (6c/12t Zen2, 39 GiB) at
    `192.168.40.9`, Proxmox VE 9.1 — a second, **standalone** host (not in a PVE
    cluster) added 2026-06. It hosts **VM 100 `ubuntu-26-desktop-node`**
    (8 vCPU / 16 GiB / 100 GiB on `local-lvm`, Ubuntu 26.04 cloud image, IP
    `192.168.40.75`) which doubles as an **XFCE desktop** and a **kubeadm
    worker** — the **fastest per-core CPU** in the cluster (Zen2 vs. the 2013
    Xeons), so it's the preferred home for CPU-bound workloads. The host's SATA
    DVD drive is passed through to the VM (`scsi2`, read-only) for ripping discs,
    and it has a 3.6 TB external LVM-thin pool. ⚠️ The board ships with **SVM
    (AMD-V) disabled in BIOS** even though the `svm` CPU flag shows — enable
    *SVM Mode* (Settings→Miscellaneous) or `kvm_amd` won't load and no VM starts.
- **Cilium** CNI (no kube-proxy); **Cilium Gateway API** for ingress + LB IPAM.
- **Rook-Ceph** for block storage (`rook-ceph-block` / RBD) — 3 OSDs (one per
  R720 node, on the NVMe), `size=2` replication, ~210 GiB usable. Manually
  managed (not in Git); dashboard at `ceph.franpolignano.com`.
- **Unraid** NAS (`192.168.40.116`) over NFS for media + config backups — below.

## NAS / Unraid storage (`192.168.40.116`)

Unraid **7.3.1** — the cluster mounts it over NFS for bulk media + nightly config
backups (anything too big or recreatable to keep on Ceph).

| Storage | FS | Size | Role |
|---|---|---|---|
| `disk1` | XFS | 11 TB (~8 TB used) | parity-protected array |
| `disk2` | XFS | 11 TB (~7 TB used) | parity-protected array |
| `cache` | btrfs | 476 GB SSD | write-cache pool |
| `/mnt/user` | shfs (FUSE) | 22 TB | merged view, NFS-exported |

- **NFS export:** `/mnt/user/FranData` (rw, `all_squash`, anonuid=99/anongid=100).
  Cluster mounts subfolders of it:
  - `FranData/immich` — Immich originals (library)
  - `FranData/immich-encoded-video` — Immich transcodes (moved off Ceph)
  - `FranData/FranHomeMedia`, `FranData/FamilyHomeMedia` — Immich external libraries (read-only)
  - `FranData/FranMedia` — Plex / Jellyfin media
  - `FranData/FranArchives/k8s-pvs/<app>` — nightly PVC config backups
- **⚠️ Stale NFS handles:** `/mnt/user` is **shfs (FUSE)**, which hands out
  *unstable* NFS file handles — when the **mover** shuffles a file cache→array
  (or shfs recycles an inode), the kubelet's cached handle goes `ESTALE` and only
  a pod recreate remounts it. Mitigations: (1) **FranData set to array-only**
  (`shareUseCache="no"`) so the mover stops churning files — the dominant trigger;
  (2) **`nfs-mount-healer`** auto-restarts affected pods. True zero-stale fix
  would be SMB (no file-handle concept) — not done.

## Applications

**Platform / infra**
| App | Purpose |
|---|---|
| `app-of-apps` | Root Application that owns all the others |
| `gateway-system` | Cilium Gateway (`main-gateway`, `*.franpolignano.com` wildcard TLS) |
| `nvidia-device-plugin` | Exposes the Tesla P4 to pods; **time-sliced** so ollama + Plex + Frigate share it |
| `nfs-provisioner` | Dynamic NFS PV provisioning |
| `nfs-mount-healer` | Restarts pods whose Unraid NFS mount goes stale (ESTALE) |
| `keycloak` | SSO / identity provider |
| `gitea` | Self-hosted git |
| `monitoring-namespace` | Owns the shared `monitoring` namespace |

**Monitoring** (`monitoring` ns)
| App | Purpose |
|---|---|
| `prometheus` | Metrics DB (stateless by design) + `weight-exporter` |
| `grafana` | Dashboards |
| `node-exporter` | Per-node host metrics (DaemonSet, `:9100`) |
| `elk` | Elasticsearch / Kibana / Logstash log stack |

**Media**
| App | Purpose |
|---|---|
| `plex`, `jellyfin` | Media servers (Plex GPU-transcodes on the P4) |
| `tautulli` | Plex stats |
| `radarr`, `sonarr` | Movie / TV automation |
| `sabnzbd` | Usenet downloader |
| `metube` | YouTube downloader |

**AI / personal / other**
| App | Purpose |
|---|---|
| `open-webui` | Chat UI + `ollama` (runs on the GPU) |
| `weight-dashboard` | Withings body-composition dashboard (feeds `weight-exporter`) |
| `steps-dashboard` | Garmin daily-steps dashboard (hourly Garmin Connect sync) |
| `heimdall` | Homelab landing page |
| `demo`, `demo2`, `python-demo`, `keycloak-demo-app` | Demos / examples |

## Access patterns

Apps are reachable two ways:

- **Gateway hostnames** (`*.franpolignano.com`, TLS via the wildcard cert) —
  for web UIs, via `HTTPRoute` on `main-gateway` (`192.168.40.202`).
  e.g. `plex`, `jellyfin`, `radarr`, `sonarr`, `sabnzbd`, `grafana`,
  `prometheus`, `gitea`, `keycloak`, `weight-dashboard`, `steps-dashboard`,
  `metube`, `tautulli`, `frigate`.
- **LoadBalancer IPs** (Cilium LB IPAM, pool `192.168.40.200-203`) — for direct
  `IP:port` access. Most share **`192.168.40.201`** via the
  `lbipam.cilium.io/sharing-key: "platform"` annotation (each on its own port):

  | IP:port | Service |
  |---|---|
  | `192.168.40.200:32400` | plex |
  | `192.168.40.201:7878` | radarr |
  | `192.168.40.201:8989` | sonarr |
  | `192.168.40.201:8080` | sabnzbd |
  | `192.168.40.201:5000` | weight-dashboard |
  | `192.168.40.201:8088` | python-demo |
  | `192.168.40.201:8086` | keycloak-demo-app |
  | `192.168.40.201:22` | gitea-ssh |
  | `192.168.40.202:80,443` | main-gateway |
  | `192.168.40.203:80` | open-webui |

## Conventions

- **Storage:** Ceph RBD (`rook-ceph-block`) for RWO configs/DBs; Unraid NFS for
  media + nightly config backups. Prometheus is intentionally **stateless**
  (ephemeral `emptyDir`, no PVC/backup).
- **RWO + `Recreate`:** apps with a ReadWriteOnce config PVC set
  `strategy: Recreate` so a rollout/move doesn't deadlock on a Multi-Attach error.
- **Secrets:** sensitive values are applied **out-of-band** as `secret.yaml`
  (gitignored via `**/secret.yaml`), with a committed template/README per app
  (e.g. `frigate`, `weight-dashboard`). Never commit a real `Secret` manifest
  into a `workloads/` dir — Argo would apply it.
- **GPU:** **Tesla P4** — 8 GB GDDR5 VRAM, 2,560 CUDA cores (Pascal, 2016),
  ~5.5 TFLOPS FP32 / ~22 TOPS INT8, 75 W single-slot, NVENC/NVDEC. Time-sliced
  (4 replicas) so multiple pods can request `nvidia.com/gpu`; consumers pinned
  with `nodeSelector: gpu=true` (frigate, immich-ML, ollama, plex).
- **Stale NFS:** Unraid `/mnt/user` (shfs FUSE) drops NFS handles periodically;
  `nfs-mount-healer` auto-recovers affected media pods.

## Adding an app

1. `workloads/<name>/<name>.yaml` — the manifests (Namespace, Deployment,
   Service, optional `HTTPRoute` / LoadBalancer, PVC, backup CronJob).
2. `apps/<name>.yaml` — an Argo `Application` pointing at `workloads/<name>`.
3. If it needs a secret: add a gitignored `secret.yaml` + a README template, and
   `kubectl apply` the secret out-of-band.
4. Commit + push. The root `app-of-apps` picks it up and Argo syncs it.

## Manual / out-of-band setup (NOT in GitOps)

ArgoCD itself bootstraps this repo, so its own install is **not** managed here
(installed from the upstream manifests). These tweaks are applied with `kubectl`
and must be **re-applied on a fresh cluster** — they don't live in Git.

### Enable the ArgoCD web terminal (exec into pods from the UI)
Off by default for security. To turn it on:

```sh
# 1. enable the feature
kubectl patch cm -n argocd argocd-cm --type merge \
  -p '{"data":{"exec.enabled":"true"}}'

# 2. grant argocd-server permission to exec into pods (not in the default role)
kubectl patch clusterrole argocd-server --type=json \
  -p '[{"op":"add","path":"/rules/-","value":{"apiGroups":[""],"resources":["pods/exec"],"verbs":["create"]}}]'

# 3. restart the server
kubectl rollout restart deploy -n argocd argocd-server
```

RBAC: the built-in `admin` user is a superuser and gets exec automatically. For
non-admin/SSO users, also add to `argocd-rbac-cm` `policy.csv`:
`p, role:admin, exec, create, */*, allow`.

Then in the UI: open an app → a Pod → the **Terminal** tab. Security note: this
lets anyone with that ArgoCD role run commands in any pod.

### Rook-Ceph (manually managed, NOT in Git)

The rook-ceph operator + CephCluster were installed from upstream manifests, so
they're **not** in this repo. Current layout: **3 OSDs**, one per node, each a
150 GB virtual disk on `speedy-nvme-drive` (NVMe); pool `replicapool` is
`size=2`/`min_size=1` (~210 GiB usable). Each node VM = 1 OS disk + 1 OSD disk.
`useAllDevices: true`, so attaching a disk to a node auto-creates an OSD.

Useful ops (via the toolbox: `kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph ...`):

```sh
ceph status; ceph osd df; ceph df            # health, OSD fill, usable space
ceph osd pool set replicapool size 2         # replication factor (2 or 3)
ceph config set osd osd_mclock_profile high_recovery_ops   # speed up backfill
```

**Grow an OSD:** `qm disk resize <vmid> scsi2 +NG` on Proxmox (live), then
`kubectl -n rook-ceph rollout restart deploy/rook-ceph-osd-<id>` (the
`expand-bluefs` init grows BlueStore). **Remove an OSD:** `ceph osd out <id>` →
wait `active+clean` → scale the OSD deploy to 0 → `ceph osd purge <id>` → delete
the deploy → delete the Proxmox disk (required, else the operator recreates it).

**⚠️ Device-path reboot gotcha:** the OSD disks are referenced by `/dev/sdX` in
each `rook-ceph-osd-<id>` deployment (`ROOK_BLOCK_PATH`). Adding/removing a node
disk can shift the kernel naming (e.g. `/dev/sdc → /dev/sdb`) on the next reboot,
after which the OSD can't find its disk and the pod fails in the `activate` init
(`lsblk: /dev/sdX: not a block device`). Fix: check the real device
(`lsblk` — the OSD one has a `bluestore block` signature), then
`kubectl -n rook-ceph set env deploy/rook-ceph-osd-<id> ROOK_BLOCK_PATH=/dev/sdX`
and restart the pod. Data is safe (BlueStore is intact on disk); the OSD just
needs the right path.

### Ceph CSI on the arm64 (M1) node

The M1 Mac node carries an `arch=arm64:NoSchedule` taint (reserves it for
deliberate placement). The rook CSI plugin DaemonSets have no tolerations by
default, so they won't schedule there — meaning no Ceph volumes on the M1 —
until you add a toleration via the operator config (out-of-band):

```sh
kubectl -n rook-ceph patch cm rook-ceph-operator-config --type merge \
  -p '{"data":{"CSI_PLUGIN_TOLERATIONS":"- effect: NoSchedule\n  key: arch\n  operator: Equal\n  value: arm64\n"}}'
kubectl -n rook-ceph rollout restart deploy rook-ceph-operator
```

Other arm64 node prep (on the Ubuntu VM, beyond the standard kubeadm steps):
- **`rbd` kernel module:** `echo rbd | sudo tee /etc/modules-load.d/rbd.conf`
  (else the RBD CSI plugin crashloops on `modprobe rbd`).
- **`nfs-common`:** `sudo apt-get install -y nfs-common` — required for any NFS
  PV to mount (`mount: ... need a /sbin/mount.<type> helper` otherwise).
- **Disable swap *persistently*:** the kubelet won't start with swap on. On
  Ubuntu 26.04 swap is **zram** (not fstab), so also
  `sudo systemctl mask systemd-zram-setup@zram0.service` — `swapoff -a` + fstab
  edits alone don't survive a reboot.

### Ceph dashboard SSL (for `ceph.franpolignano.com`)

The `HTTPRoute` is in Git (`workloads/ceph-dashboard/`) but the dashboard's SSL
must be disabled out-of-band so the gateway can proxy plain HTTP:

```sh
kubectl -n rook-ceph patch cephcluster rook-ceph --type merge \
  -p '{"spec":{"dashboard":{"ssl":false}}}'           # flips :8443 https -> :7000 http
kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath='{.data.password}' | base64 -d; echo    # admin password
```

**Changing the password:** don't use the dashboard UI — rook reverts it to the
secret. Update the secret, then apply it live:
```sh
kubectl -n rook-ceph create secret generic rook-ceph-dashboard-password \
  --from-literal=password='NEW' --dry-run=client -o yaml | kubectl apply -f -
PWB64=$(kubectl -n rook-ceph get secret rook-ceph-dashboard-password -o jsonpath='{.data.password}')
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- sh -c \
  "echo '$PWB64' | base64 -d > /tmp/p && ceph dashboard ac-user-set-password admin -i /tmp/p; rm -f /tmp/p"
```
