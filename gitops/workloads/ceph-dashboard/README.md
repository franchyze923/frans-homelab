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

## Physical OSD drives — DONE 2026-08-01

`failureDomain: host` in the `CephBlockPool` only protects against a *k8s node*
going down, not a *physical machine* going down. Two of the original three
OSDs lived on VMs on the same Proxmox box (`pve @ 192.168.40.10`), so losing
that one box would have stranded 2 of 3 replicas. Fixed: exactly 3 OSDs now,
one per genuinely distinct physical machine.

| OSD | k8s node | Physical host | Drive |
|-----|----------|----------------|-------|
| osd.4 | k8s-cluster-prod-master | pve @ .10 (R720) | Samsung 870 EVO |
| osd.1 | k8s-cp-old-ryzen-node | fran @ .9 (Ryzen) | Inland Professional 512GB |
| osd.0 | k8s-cp-truenas-node | TrueNAS (bare metal) | `VM_Pool/for-ceph` zvol |

**How it got there:** added a 4th OSD (`osd.1`) on `fran @ 192.168.40.9`
(the Ryzen box, physically distinct from pve) — an Inland Professional 512GB
SSD (450MB/s write / 520MB/s read, Micro Center) pulled from the Unraid
backup NAS's (`192.168.40.116`) unused cache slot. Passed through raw to VM
101 (`k8s-cp-old-ryzen-node`) via Proxmox (`qm set 101 -scsi1
/dev/disk/by-id/ata-SATA_SSD_22112951203102`); had to `wipefs`/clear a
leftover Unraid btrfs signature + DDF RAID metadata before Rook would claim
it as clean.

Bumped `old-ryzen-node` from 2→4 vCPUs first (taking 2 from `desktop-node`,
10→8) — it's a stacked etcd member, and only 2 cores was too tight to safely
absorb OSD backfill CPU load without risking etcd latency. The Ryzen host has
exactly 12 threads total (6C/12T), fully committed between the two VMs, so
there's no spare headroom beyond that trade.

Then removed `osd.3` (`k8s-cluster-prod-worker-1`, pve) rather than keeping
all 4: with `failureDomain: host` and 3x replication, a 4th host only gives
CRUSH a *choice* of which 3-of-4 to use per PG — math works out to ~50% of
PGs still landing on both pve nodes, not the hard guarantee we were after.
(The alternative — Rook `topology.rook.io/chassis` labels to group
`master`+`worker-1` as one failure domain and keep all 4 OSDs — would have
preserved full weighted capacity, but was skipped for simplicity.)
Consequence of exactly 3 hosts: since `replicas == hosts`, every PG uses all
3, so all three drives hold a full copy regardless of size — pool capacity is
capped at the smallest OSD (TrueNAS, 135GB), wasting most of the new 512GB
drive's headroom. Accepted as a deliberate simplicity trade-off.

Removal sequence used: `ceph osd out osd.3` → waited for backfill to fully
drain it (0 bytes) → deleted the `rook-ceph-osd-3` deployment → `ceph osd
purge osd.3 --yes-i-really-mean-it` → `ceph osd crush remove
k8s-cluster-prod-worker-1` (drops the now-empty host bucket) → deleted the
underlying Proxmox disk (`vm-136-disk-2` on `pve@.10`, VM 136) via `qm set
136 -delete scsi2` **and** `pvesm free speedy-nvme-drive:vm-136-disk-2` (the
`qm set -delete` alone only unlinks the disk from the VM config — the
volume keeps existing in storage until `pvesm free` actually removes it).
Skipping either step risks `useAllDevices: true` re-claiming a
wiped-but-still-attached disk as a phantom new OSD on the next Rook
reconcile.
