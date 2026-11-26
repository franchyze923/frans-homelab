# forgejo

Trial deployment of [Forgejo](https://forgejo.org) (the Gitea fork), running
alongside the existing `gitea` app to compare the two. Same shape as the gitea
workload: single pod, sqlite, everything under `/data` on one RBD PVC.

- **URL:** https://forgejo.franpolignano.com (Pi-hole wildcard → gateway)
- **Git over SSH:** `ssh://git@192.168.40.201:2222/<user>/<repo>.git`
  (shared "platform" LB IP; gitea owns port 22). Use the LAN IP, as with
  gitea -- the hostname resolves to the HTTP gateway (`.202`), not `.201`.
- **Storage:** `forgejo-data` PVC (rook-ceph-block, RWO, 5 Gi).
- **Image:** `codeberg.org/forgejo/forgejo`, pinned (one-way DB migrations).
- **No backup yet.** Unlike gitea there is no nightly NFS backup CronJob;
  add one (copy gitea's, with the podAffinity) before trusting it with repos
  that live nowhere else.

## Admin account

The install wizard is skipped (`INSTALL_LOCK`) and self-registration is
disabled, so users are created from the CLI. Admin credentials are in
`cluster/forgejo-credentials.txt` (gitignored). To create another user:

```sh
kubectl -n forgejo exec deploy/forgejo -- su-exec git \
  forgejo admin user create --username <name> --email <email> \
  --random-password [--admin]
```

## Removing the trial

Delete `gitops/apps/forgejo.yaml` and this directory; app-of-apps prunes the
Application and its finalizer removes the namespace (PVC included).
