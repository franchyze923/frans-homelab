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

### Proxmox hosts

| Host | CPU | RAM | Notes |
|---|---|---|---|
| **Dell R720** | 2× Xeon E5-2660 v2 (20c / 40t, 2013) | — | Primary host. Runs control-plane + 2 Rocky workers + the M1 arm64 VM off a single NVMe (`speedy-nvme-drive`). |
| **Gigabyte B450M** @ `192.168.40.9` | Ryzen 5 3600 (6c / 12t, Zen2) | 39 GiB | Standalone (not in a PVE cluster), Proxmox VE 9.1, added 2026-06. Fastest per-core CPU → preferred home for CPU-bound work. SATA DVD passed through for ripping; 3.6 TB external LVM-thin pool. ⚠️ Needs **SVM Mode** enabled in BIOS or no VM starts. |

### Cluster nodes — kubeadm, mixed-arch (5× amd64 + 1× arm64)

| Node | Arch | Host / hardware | Role |
|---|---|---|---|
| control-plane | amd64 | R720 VM | Control plane |
| worker ×2 (Rocky Linux) | amd64 | R720 VMs | Workers + Ceph OSDs |
| `ubuntu24-gpu-box` | amd64 | Ubuntu, **Tesla P4** GPU | GPU workloads (Plex, ollama, Frigate, Immich-ML) |
| `ubuntu-26-desktop-node` | amd64 | VM 100 on B450M (`192.168.40.75`, 8 vCPU / 16 GiB / 100 GiB, Ubuntu 26.04) | Worker + doubles as an XFCE desktop |
| `mac-m1-worker` | **arm64** | M1 Mac VM on R720 | arm64 worker (tainted `arch=arm64:NoSchedule`) |

**GPU — Tesla P4:** 8 GB GDDR5, 2,560 CUDA cores (Pascal), 75 W single-slot, NVENC/NVDEC. **Time-sliced** (4 replicas) so Plex + ollama + Frigate + Immich-ML share it; consumers pinned with `nodeSelector: gpu=true`.

### NAS — Unraid 7.3.1 @ `192.168.40.116`

NFS-exported to the cluster for bulk media + nightly config backups (anything too big or recreatable for Ceph).

| Storage | FS | Size | Role |
|---|---|---|---|
| `disk1` / `disk2` | XFS | 11 TB each | Parity-protected array |
| `cache` | btrfs | 476 GB SSD | Write-cache pool |
| `/mnt/user` | shfs (FUSE) | 22 TB | Merged view, NFS-exported as `/mnt/user/FranData` |

> ⚠️ `/mnt/user` is shfs (FUSE) and hands out unstable NFS handles → pods hit `ESTALE`. Mitigated by setting `FranData` array-only (`shareUseCache=no`) + the `nfs-mount-healer` app. See [`gitops/README.md`](gitops/README.md) for detail.

### Storage — Rook-Ceph

Block storage (`rook-ceph-block` / RBD): 3 OSDs (one per R720 node, on NVMe), `size=2`, ~210 GiB usable. **Managed out-of-band** (not in Git) — runbook in [`gitops/README.md`](gitops/README.md).

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
