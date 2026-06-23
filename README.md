# Homelab — Argo CD App-of-Apps

GitOps configuration for my homelab Kubernetes cluster. Everything that runs on
the cluster is declared here; **Argo CD** continuously syncs this repo to the
cluster, so `git push` is the deploy mechanism.

See [CHANGELOG.md](CHANGELOG.md) for a running history of changes.

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
  (`ubuntu24-gpu-box`, Ubuntu, Tesla P4).
- **Cilium** CNI (no kube-proxy); **Cilium Gateway API** for ingress + LB IPAM.
- **Rook-Ceph** for block storage (`rook-ceph-block` / RBD).
- **Unraid** NAS (`192.168.40.116`) over NFS for media + config backups.

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
| `heimdall` | Homelab landing page |
| `demo`, `demo2`, `python-demo`, `keycloak-demo-app` | Demos / examples |

## Access patterns

Apps are reachable two ways:

- **Gateway hostnames** (`*.franpolignano.com`, TLS via the wildcard cert) —
  for web UIs, via `HTTPRoute` on `main-gateway` (`192.168.40.202`).
  e.g. `plex`, `jellyfin`, `radarr`, `sonarr`, `sabnzbd`, `grafana`,
  `prometheus`, `gitea`, `keycloak`, `weight-dashboard`, `metube`, `tautulli`, `frigate`.
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
- **GPU:** the P4 is time-sliced (4 replicas) so multiple pods can request
  `nvidia.com/gpu`. GPU consumers are pinned with `nodeSelector: gpu=true`.
- **Stale NFS:** Unraid `/mnt/user` (shfs FUSE) drops NFS handles periodically;
  `nfs-mount-healer` auto-recovers affected media pods.

## Adding an app

1. `workloads/<name>/<name>.yaml` — the manifests (Namespace, Deployment,
   Service, optional `HTTPRoute` / LoadBalancer, PVC, backup CronJob).
2. `apps/<name>.yaml` — an Argo `Application` pointing at `workloads/<name>`.
3. If it needs a secret: add a gitignored `secret.yaml` + a README template, and
   `kubectl apply` the secret out-of-band.
4. Commit + push. The root `app-of-apps` picks it up and Argo syncs it.
