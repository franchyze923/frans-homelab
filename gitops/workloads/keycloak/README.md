# keycloak

Keycloak 26 (pinned) at `keycloak.franpolignano.com` — the homelab's SSO
identity provider. Realm **`homelab`**, user **`fran`**. Data on Ceph with the
standard nightly NFS backup.

## Secret (applied out-of-band, NOT in git)

Bootstrap admin credentials live in Secret `keycloak-admin-creds` (only read
on a fresh-database first boot; the live password is in Keycloak's DB).
`secret.yaml` is gitignored. Template:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-admin-creds
  namespace: keycloak
type: Opaque
stringData:
  username: "admin"
  password: "REPLACE_ME"
```

## SSO clients (realm `homelab`)

Client secrets live in Keycloak (admin console → Clients → Credentials) and
in each consumer's out-of-band Secret:

| Client | App config | Secret (out-of-band) |
|---|---|---|
| `argocd` | `argocd-cm` `oidc.config` + `argocd-rbac-cm` (managed out-of-band, kubectl) | key `oidc.keycloak.clientSecret` in `argocd-secret` |
| `grafana` | env in `workloads/grafana/grafana.yaml` | `grafana-oidc` in ns `monitoring` |
| `gitea` | auth source in Gitea DB (`gitea admin auth list`) | in Gitea's DB |
| `immich` | system config via Immich admin API/UI | in Immich's DB |
| `open-webui` | env in `workloads/open-webui/open-webui.yaml` | `openwebui-oidc` in ns `open-webui` |

On a Keycloak rebuild: recreate realm `homelab`, user `fran`, and the five
clients (redirect URIs are `https://<app hostname>/<provider callback>`), then
refresh each consumer's secret. Or restore the nightly backup, which includes
the Keycloak DB.

No SSO (no native OIDC): plex, jellyfin*, radarr/sonarr/sabnzbd, tautulli,
metube, heimdall, prometheus, frigate, ELK (paid feature), ceph dashboard
(SAML only). *jellyfin has a community SSO plugin if ever wanted.
