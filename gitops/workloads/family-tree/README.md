# family-tree

Self-hosted genealogy app ("Family Tree Maker, but simple") designed so older
relatives can edit it themselves: large type, big buttons, plain-language
forms, free-text dates. Source lives in the `family-tree` repo; image is
`franchyze923/family-tree` on Docker Hub.

- **URL:** https://family-tree.franpolignano.com (Pi-hole wildcard → gateway)
- **Storage:** `family-tree-data` PVC (rook-ceph-block, RWO) holds
  `familytree.db` (SQLite) and `photos/`. Nothing sensitive in git or the
  image; no secrets needed.
- **Backups:** the UI has "Download a backup" (JSON, everything except photo
  binaries). Photos live only on the PVC — if they start accumulating,
  consider a CronJob copy to the NAS like the other backup jobs.

## Rebuild / update

```sh
cd ~/repos/family-tree
podman build -t docker.io/franchyze923/family-tree:latest .
podman push docker.io/franchyze923/family-tree:latest
kubectl -n family-tree rollout restart deploy/family-tree   # imagePullPolicy: Always
```
