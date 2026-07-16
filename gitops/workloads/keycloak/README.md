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
clients (redirect URIs are `https://<app hostname>/<provider callback>`; the
`argocd` client additionally allows `http://localhost:8085/auth/callback` for
the CLI and `argocd://auth/callback` for the mobile app, and is a **public**
client — no client secret required, so the mobile app can log in), then
refresh each consumer's secret. Or restore the nightly backup, which includes
the Keycloak DB.

## Realm session settings (changed 2026-07-16)

Defaults (30 min idle / 10 h max) forced a re-login on every app after half
an hour away. Now: **SSO Session Idle 14 d, Max 30 d, Remember Me on** —
set via the admin REST API (admin password: `cluster/keycloak-credentials.txt`;
Keycloak has no realm-settings CLI in-container, the API is the scriptable path):

```sh
TOKEN=$(curl -fsS "https://keycloak.franpolignano.com/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d username=admin -d "password=$KC_ADMIN_PASS" \
  -d grant_type=password | jq -r .access_token)
curl -fsS -X PUT "https://keycloak.franpolignano.com/admin/realms/homelab" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"ssoSessionIdleTimeout": 1209600, "ssoSessionMaxLifespan": 2592000, "rememberMe": true}'
```

Access-token lifespan stays at the 5-min default (renews silently while the
SSO session is alive). Re-apply after any realm rebuild — this is not in the
realm defaults.

No SSO (no native OIDC): plex, jellyfin*, radarr/sonarr/sabnzbd, tautulli,
metube, heimdall, prometheus, frigate, ELK (paid feature), ceph dashboard
(SAML only), navidrome (reverse-proxy header auth only). *jellyfin has a community SSO plugin if ever wanted.
