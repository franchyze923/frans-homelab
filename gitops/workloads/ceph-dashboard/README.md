# ceph-dashboard

Exposes the **Rook-Ceph mgr dashboard** at `https://ceph.franpolignano.com`
(cluster health, OSDs, pools, PGs, capacity, hosts, RBD images, throughput).

Only the `HTTPRoute` is in Git. The dashboard is part of the **manually managed**
rook-ceph install, so two things are applied out-of-band with `kubectl` and must
be re-applied on a fresh cluster:

```sh
# 1. disable the dashboard's own SSL so the gateway terminates TLS and proxies
#    plain HTTP to the service (flips it from :8443 https to :7000 http)
kubectl -n rook-ceph patch cephcluster rook-ceph --type merge \
  -p '{"spec":{"dashboard":{"ssl":false}}}'

# 2. get the auto-generated admin password (username: admin)
kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Then point DNS `ceph.franpolignano.com` → `192.168.40.202` (the gateway) and log
in as `admin`.

## Physical OSD drives

`failureDomain: host` in the `CephBlockPool` only protects against a *k8s node*
going down, not a *physical machine* going down — two of the three OSDs below
currently live on VMs on the same Proxmox box (`pve @ 192.168.40.10`), so
losing that one box strands 2 of 3 replicas.

| OSD | k8s node | Physical host | Drive |
|-----|----------|----------------|-------|
| osd.4 | k8s-cluster-prod-master | pve @ .10 (R720) | Samsung 870 EVO |
| osd.3 | k8s-cluster-prod-worker-1 | pve @ .10 (R720) | Samsung 980 PRO |
| osd.0 | k8s-cp-truenas-node | TrueNAS (bare metal) | `VM_Pool/for-ceph` zvol |

**In progress:** moving a 4th OSD onto `fran @ 192.168.40.9` (the Ryzen box,
physically distinct from pve) to get true 3-way physical spread, then purging
whichever pve-hosted OSD ends up redundant. Drive: **Inland Professional
512GB** (450MB/s write / 520MB/s read, Micro Center), pulled from the Unraid
backup NAS's (`192.168.40.116`) unused cache slot — it wasn't backing any
active Docker/VM workload there.
