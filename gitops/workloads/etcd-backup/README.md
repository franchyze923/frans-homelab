# etcd-backup

Nightly CronJob (2:15 AM) that snapshots the cluster's etcd to the Unraid NAS
(`k8s-pvs/etcd-snapshots`), keeping the newest 14. This is the disaster net
for a dead control plane: with a snapshot, a rebuilt cluster comes back with
every namespace, secret, PVC binding, and Argo app intact.

## How it works

- Runs on a control-plane node (`nodeSelector` + toleration) with
  `hostNetwork: true`, so `etcdctl` reaches the local etcd member at
  `127.0.0.1:2379` using the kubeadm `healthcheck-client` cert mounted from
  the host's `/etc/kubernetes/pki/etcd`.
- Uses the same `registry.k8s.io/etcd` image version as the cluster's etcd
  static pods — keep them in step when upgrading Kubernetes.
- Any member's snapshot is a complete copy, so this works unchanged after the
  control plane goes HA (it just runs on whichever master schedules it).

## Restore (sketch)

On a fresh control-plane node, before `kubeadm init`:

```sh
etcdutl snapshot restore etcd-snapshot-<date>.db --data-dir /var/lib/etcd
kubeadm init --ignore-preflight-errors=DirAvailable--var-lib-etcd ...
```

Full procedure: https://kubernetes.io/docs/tasks/administration/configure-upgrade-etcd/

## Verify

```sh
kubectl -n etcd-backup create job --from=cronjob/etcd-snapshot etcd-snapshot-manual
kubectl -n etcd-backup logs job/etcd-snapshot-manual -f
ssh root@192.168.40.116 'ls -lh /mnt/user/FranData/FranArchives/k8s-pvs/etcd-snapshots/'
```
