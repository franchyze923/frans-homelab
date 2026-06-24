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
