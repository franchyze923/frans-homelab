# gift-list

Polignano family Christmas gift list: one shared page where everyone has a
section, anyone can add gifts, and others cross them off once bought (hidden
from the person whose section it is). Flask/gunicorn + SQLite. Source lives
in the (private) `gift-list` repo; image is `franchyze923/gift-list` on
Docker Hub.

- **URL:** https://gift-list.franpolignano.com (Pi-hole wildcard → gateway)
- **Storage:** `gift-list-data` PVC (rook-ceph-block, RWO) holds `list.db`.
  Nothing sensitive in git or the image.
- **Separate from Fly.io:** the public copy at
  https://wishlist.polignanofamily.com runs on Fly with its own database.
  This instance starts empty; nothing syncs between the two.

## Family password (optional, out-of-band)

Without the Secret the list opens with no prompt. To require the shared
password, create the Secret (not in git) and restart:

```sh
kubectl -n gift-list create secret generic gift-list-password \
  --from-literal=FAMILY_PASSWORD='...'
kubectl -n gift-list rollout restart deploy/gift-list
```

## Rebuild / update

```sh
cd ~/repos/gift-list
podman build -t docker.io/franchyze923/gift-list:latest .
podman push docker.io/franchyze923/gift-list:latest
kubectl -n gift-list rollout restart deploy/gift-list   # imagePullPolicy: Always
```

## Admin

```sh
kubectl -n gift-list exec deploy/gift-list -- python app.py people
kubectl -n gift-list exec deploy/gift-list -- python app.py add-person Nonna
kubectl -n gift-list exec deploy/gift-list -- python app.py removed
kubectl -n gift-list exec deploy/gift-list -- python app.py restore 12
```
