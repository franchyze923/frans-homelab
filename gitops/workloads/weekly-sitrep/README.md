# weekly-sitrep

Weekly project status reports at `sitrep.franpolignano.com`. Source and
docs: repo `weekly-sitrep`. Image `franchyze923/weekly-sitrep` on Docker
Hub, built and pushed by hand (`podman build --build-arg APP_BUILD=$(git
rev-parse --short HEAD) ...`); `GET /healthz` reports version + commit.

SQLite on a 1 Gi Ceph RBD PVC at `/data`, single replica, Recreate.

## Secret (applied out-of-band, NOT in git)

```sh
kubectl -n weekly-sitrep create secret generic weekly-sitrep-oidc \
  --from-literal=SESSION_SECRET="$(openssl rand -hex 32)" \
  --from-literal=OIDC_CLIENT_SECRET="<Keycloak → Clients → weekly-sitrep → Credentials>"
```

## Login

Keycloak client `weekly-sitrep` (realm `homelab`, see `../keycloak/README.md`)
or built-in users:

```sh
kubectl -n weekly-sitrep exec deploy/weekly-sitrep -- python -m app.users add you@example.com --name "You" --password '...'
kubectl -n weekly-sitrep exec deploy/weekly-sitrep -- python -m app.users list
```
