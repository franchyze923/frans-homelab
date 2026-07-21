# frans-homelab

Everything that builds and runs my homelab Kubernetes cluster, in one repo.

It has two layers:

| Layer | Directory | What it does | Changes |
|---|---|---|---|
| **Cluster** | [`cluster/`](cluster/) | Provisions the cluster from scratch — Proxmox VMs (Terraform) + Kubernetes, CNI, storage (Ansible). Bootstraps Argo CD. | Rarely |
| **GitOps** | [`gitops/`](gitops/) | Every app that runs on the cluster, declared for Argo CD. `git push` is the deploy mechanism. | Often |

```
frans-homelab/
├── cluster/            # was k8s-fun  — terraform + ansible, deploy.sh / destroy.sh
│   ├── terraform/      #   Proxmox VM definitions
│   ├── ansible/        #   k3s/kubeadm, Cilium, Ceph, ArgoCD, ...
│   └── README.md       #   full cluster-deploy docs
├── gitops/             # was app-of-apps  — Argo CD app-of-apps
│   ├── apps/           #   one Argo CD Application per app (root: app-of-apps.yaml)
│   ├── workloads/      #   the actual k8s manifests each Application points at
│   └── README.md       #   full GitOps + ops-runbook docs
└── README.md           # you are here
```

> **Bootstrap order:** `cluster/` builds the cluster **and installs Argo CD**, then points Argo CD at `gitops/apps`, which deploys everything else. So: **cluster first, GitOps second.**

---

## Hardware

### Physical hosts

Five bare-metal machines. The first four carry the cluster — Kubernetes nodes are **VMs on top of them** (see the next table). The fifth (`fran-lenovo-rocky-9`) is the standalone devbox and is **not part of the cluster**. Inventoried live over SSH, 2026-06-29; devbox added 2026-07-16.

#### `pve` — Dell PowerEdge R720 · `192.168.40.10`
Primary Proxmox host — runs master-1, the Rocky workers, and the M1 VM.

- **CPU:** 2× Xeon E5-2660 v2 — 20c / 40t @ 2.2–3.0 GHz
- **RAM:** 192 GB DDR3-1866 — 12× 16 GB, 188 GiB usable (24 slots, max 1.5 TB)
- **OS:** Proxmox VE 9.2.3 / Debian 13 (kernel 7.0.6)
- **Storage:** 1 TB Samsung 980 PRO NVMe (`speedy-nvme-drive` LVM-thin — all
  k8s VM OS disks + worker-1's 150 G Ceph OSD; ~460 G free) + 500 GB Samsung
  870 EVO SATA SSD (Proxmox OS on `local-lvm`, plus master-1's 150 G Ceph OSD
  disk — moved off the NVMe 2026-07-07 for drive-level Ceph redundancy)

#### `fran` — Gigabyte B450M DS3H · `192.168.40.9`
Secondary standalone Proxmox host — Ryzen worker VM + XFCE desktop. Fastest per-core CPU → preferred home for CPU-bound workloads.

- **CPU:** Ryzen 5 3600 — 6c / 12t @ ≤4.2 GHz (Zen2)
- **RAM:** 40 GB DDR4-2133 — 16+8+16 GB, 39 GiB usable (4 slots, max 128 GB)
- **OS:** Proxmox VE 9.1.7 / Debian 13 (kernel 6.17.13)
- **Storage:** 250 GB Samsung 850 EVO SATA SSD (s/n `S2R5NX0H437857T`,
  ~26k h / ~26 TB written, healthy — `local-lvm`, hosts master-2's 50 G disk)
  + 4 TB Toshiba HDWE140 **internal** SATA HDD (VG `fran-4-tb-external` — the
  name lies) + DVD-RW
- ⚠️ Board ships with **SVM (AMD-V) disabled in BIOS** even though the `svm` flag shows — enable *SVM Mode* or `kvm_amd` won't load and no VM starts.

#### `UnraidBackup` — Dell EMC Avamar datastore (Intel S2600GZ board) · `192.168.40.116`
NAS — bulk media + nightly config backups, NFS-exported to the cluster.

- **CPU:** Xeon E5-2603 — 4c / 4t @ 1.8 GHz (no HT)
- **RAM:** 64 GB DDR3-1600 — 8× 8 GB, 63 GiB usable (16 slots, max 256 GB)
- **OS:** Unraid 7.3.1 (kernel 6.18.33)
- **Storage:** 2× 10.9 TB HDD array + 476 GB SSD cache (Intel RMS25CB080 HBA) + 16 GB boot USB

#### `truenas` — Dell PowerEdge R720 · `192.168.40.240`
NAS — TrueNAS SCALE (ZFS). The homelab's second R720.

- **CPU:** 2× Xeon E5-2640 — 12c / 24t @ 2.5–3.0 GHz
- **RAM:** ~110 GiB DDR3 usable (likely 128 GB; DIMM layout not enumerated — no root)
- **OS:** TrueNAS SCALE 25.10.3.1 / Debian 12 (kernel 6.12.33)
- **Storage:** 5× 5 TB Seagate ST5000LM000 HDD (ZFS `FranPool`, ~23 TB raw)
  + 2× 256 GB SSDs — **likely Inland Professional** (Micro Center purchase;
  Phison-controller white-label, model string just "SATA SSD"), behind the
  SAS HBA: boot-pool (s/n `21120225603051`) and `VM_Pool`
  (s/n `22082325601847`, fw SBFM61.5, 88% life — hosts master-3's 40 G zvol;
  reclaimed 2026-07-06 from the legacy "Plex Pool") + DVD-RW

#### `fran-lenovo-rocky-9` — Lenovo ThinkCentre M710q (10MR0004US) · `192.168.40.192`
Devbox / workstation (`fsp` in SSH config) — **not a cluster member**, deliberately
(2026-07-16): only 4 threads and it's the interactive dev machine, so joining it
would couple the workspace to cluster scheduling for ~5% more capacity. Kaby Lake
has AVX2, so per-core it actually out-encodes the R720's Ivy Bridge Xeons at 35 W.

- **CPU:** i5-7500T — 4c / 4t @ 2.7–3.3 GHz (Kaby Lake, 35 W)
- **RAM:** 16 GB DDR4, 15 GiB usable (layout not enumerated — no passwordless sudo; 2 SODIMM slots, max 32 GB)
- **OS:** Rocky Linux 9.8 (kernel 5.14.0-611.5.1.el9_7)
- **Storage:** 256 GB Samsung PM981 NVMe (`MZVLB256HAHQ`) — OS only, no spare disk for Ceph

### Kubernetes nodes (VMs)

VMs running **on the physical hosts above** — kubeadm, mixed-arch (7× amd64 +
1× arm64). **HA control plane (2026-07-07):** 3 masters, one per physical
machine, behind **kube-vip VIP `192.168.40.171`** (the API endpoint for
kubeconfigs, kubelets, and Cilium):

| Node | Arch | Runs on | Role |
|---|---|---|---|
| `k8s-cluster-prod-master` | amd64 | `pve` (R720), VM 135 (`.172`) | Control plane 1/3 + Ceph OSD (870 EVO) + mon `c` |
| `k8s-cp-old-ryzen-node` | amd64 | `fran` (B450M), VM 101 (`.108`, 2 vCPU / 8 GiB / 50 GiB) | Control plane 2/3 |
| `k8s-cp-truenas-node` | amd64 | `truenas` VM (`.249`, 2 vCPU / 8 GiB / 50 GiB, on `VM_Pool` SSD) | Control plane 3/3 + Ceph OSD (135 G zvol) + mon `e` |
| worker ×2 (Rocky Linux) | amd64 | `pve` (R720) | Workers (worker-1 also carries a Ceph OSD on the NVMe) |
| `ubuntu24-gpu-box` | amd64 | `pve` (R720), **Tesla P4** (GPU passthrough), 20 vCPU (raised from 12, 2026-07-21) | GPU workloads (Plex, ollama, Frigate, Immich-ML, nvidia-gpu-exporter) |
| `ubuntu-26-desktop-node` | amd64 | `fran` (B450M), VM 100 (`192.168.40.76`, 10 vCPU / 16 GiB / 100 GiB, Ubuntu 26.04) | Worker + XFCE desktop + mon `d` |
| `mac-m1-worker` | **arm64** | M1 Mac VM on `pve` | arm64 worker (tainted `arch=arm64:NoSchedule`) |

**GPU — Tesla P4:** 8 GB GDDR5, 2,560 CUDA cores (Pascal), 75 W single-slot, NVENC/NVDEC (incl. HEVC Main10/10-bit encode). **Time-sliced** (5 replicas, raised from 4 on 2026-07-21 to fit `nvidia-gpu-exporter`) so Plex + ollama + Frigate + Immich-ML + the exporter share it; consumers pinned with `nodeSelector: gpu=true`.

**GPU — AMD Radeon RX 570** (removed 2026-07-21, same day it went in): briefly passed through to `ubuntu-26-desktop-node` as an alternative to sharing the P4, but VCE 3.4 has **no HEVC Main10 (10-bit) encode entrypoint** -- confirmed with [`gitops/scripts/gpu-transcode-bench.sh`](gitops/scripts/README.md) -- and the media-reencode worker's whole library is 10-bit HEVC, so every HEVC-target transcode (e.g. Apple TV) silently fell back to full CPU software encode. Plex moved back to the P4 the same day; no other current workload (Jellyfin was considered) justified keeping a second GPU powered on, so `hostpci0` was removed from VM 100 and the card physically pulled to save power. `generic-device-plugin` (only ever used for this card) removed from git along with it.

### Storage

**Unraid NFS** (`192.168.40.116`) — bulk media + nightly config backups (anything too big or recreatable for Ceph):

| Storage | FS | Size | Role |
|---|---|---|---|
| `disk1` / `disk2` | XFS | 11 TB each | Parity-protected array |
| `cache` | btrfs | 476 GB SSD | Write-cache pool |
| `/mnt/user` | shfs (FUSE) | 22 TB | Merged view, NFS-exported as `/mnt/user/FranData` |

> ⚠️ `/mnt/user` is shfs (FUSE) and hands out unstable NFS handles → pods hit `ESTALE`. Mitigated by setting `FranData` array-only (`shareUseCache=no`) + the `nfs-mount-healer` app. See [`gitops/README.md`](gitops/README.md) for detail.
> The healer only covers the media namespaces — **backup CronJobs are not covered**, and with `concurrencyPolicy: Forbid` a single pod wedged on a dead mount silently blocks all future backups (bit etcd for 3.5 days, 2026-07-10). After a NAS event, sweep non-Running pods and each backup CronJob's `lastSuccessfulTime`; the fix is deleting the pod/job (container restarts don't remount).

**Rook-Ceph** — block storage (`rook-ceph-block` / RBD): 3 OSDs, **one per
physical drive** (2026-07-07): `osd.3` 150 G on the `pve` 980 PRO NVMe
(worker-1), `osd.4` 150 G on the `pve` 870 EVO (master), `osd.0` 135 G on the
truenas `VM_Pool` SSD (`k8s-cp-truenas-node`, zvol `VM_Pool/for-ceph`).
`size=2` + one-OSD-per-node ⇒ every PG's replicas land on two different
drives — **any single drive can die without data loss** (whole-R720 loss
still risks PGs whose pair was 980+870). ~185 GiB usable. All three OSDs
bench healthy when idle (65–175 MiB/s 4M writes, ~4.2–7.6 k IOPS 4K). MONs `c`/`d`/`e` pinned
via `ceph-mon=true` node labels to one per physical machine. ⚠️ CephCluster
runs `useAllNodes/useAllDevices: true` — any empty raw disk attached to any
node becomes an OSD automatically. **Managed out-of-band** (not in Git) —
runbook in [`gitops/README.md`](gitops/README.md).

---

## Network

- **CNI:** Cilium (no kube-proxy) + **Cilium Gateway API** for ingress & LB IPAM.
- **Gateway:** `main-gateway` at **`192.168.40.202`**, wildcard TLS for `*.franpolignano.com`. Web UIs reach the cluster via `HTTPRoute`.
- **LoadBalancer pool:** `192.168.40.200–203` (Cilium LB IPAM). Most services share `192.168.40.201` via the `lbipam.cilium.io/sharing-key: "platform"` annotation.

| IP:port | Service |
|---|---|
| `192.168.40.200:32400` | plex |
| `192.168.40.201:7878` | radarr |
| `192.168.40.201:8989` | sonarr |
| `192.168.40.201:8080` | sabnzbd |
| `192.168.40.201:5000` | weight-dashboard |
| `192.168.40.202:80,443` | main-gateway (all `*.franpolignano.com` web UIs) |
| `192.168.40.203:80` | open-webui |

(Full list in [`gitops/README.md`](gitops/README.md).)

---

## Deploy a cluster

Full docs: [`cluster/README.md`](cluster/README.md). Quick version:

```bash
cd cluster

# 1. Configure (both files are gitignored)
cp config.yml.example config.yml
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
#   - config.yml: IPs, cluster settings, app toggles, and the argocd block
#                 (already defaulted to this repo: repo_url=frans-homelab, path=gitops/apps)
#   - terraform.tfvars: Proxmox password + SSH public key

# 2. Deploy (Terraform builds VMs, Ansible installs k8s + Cilium + ArgoCD)
./deploy.sh
#   or override: ./deploy.sh kubeadm metallb --memory 8192 --cores 4

# 3. Use it
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```

With `apps.argocd: true`, the bootstrap installs Argo CD and applies the root
`app-of-apps` Application pointing at **`gitops/apps`** in this repo — so the
GitOps layer comes up on its own.

**Tear down:** `cd cluster && ./destroy.sh` (`--cluster <name>` for a specific one).

---

## Deploy / change apps (GitOps)

Full docs + ops runbook: [`gitops/README.md`](gitops/README.md). The flow:

1. `gitops/workloads/<name>/` — the k8s manifests.
2. `gitops/apps/<name>.yaml` — an Argo CD `Application` pointing at `gitops/workloads/<name>`.
3. Secrets go in a gitignored `secret.yaml` applied out-of-band (never commit a real Secret).
4. `git push` — the root `app-of-apps` picks it up and Argo syncs within a few minutes.

All apps run with **automated sync, prune, and self-heal**, so `main` and the cluster stay in lock-step.
