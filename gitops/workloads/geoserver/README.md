# geoserver

GeoServer (OGC WMS/WFS/WCS map server) — first piece of the geospatial suite.
Runs `kartoza/geoserver` (Docker Hub) pinned to the stable 2.28.x line; the
3.0.0 images exist but extensions still lag it.

- UI: https://geoserver.franpolignano.com/geoserver/web/ (covered by the
  Pi-hole `*.franpolignano.com` wildcard)
- Data dir on Ceph RBD (`geoserver-data`), nightly tarball backup to Unraid NFS
  at 03:00 (staggered from jellyfin's 02:00), auto-restore initContainer on
  empty data dir — same pattern as jellyfin.

## Secret (applied out-of-band, NOT in git)

The admin password lives in Secret `geoserver-admin`. The pod won't start
until it exists. Plaintext copy kept in `cluster/geoserver-credentials.txt`
(gitignored). Template:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: geoserver-admin
  namespace: geoserver
type: Opaque
stringData:
  GEOSERVER_ADMIN_PASSWORD: "REPLACE_ME"
```

Login: `admin` / that password. On a cluster rebuild, re-apply the secret and
the restore initContainer brings the data dir back from the NFS backup.

## Proxy base URL

TLS terminates at `main-gateway`, so `HTTPS_PROXY_NAME/PORT` + `HTTP_SCHEME`
make capabilities documents advertise `https://geoserver.franpolignano.com`
instead of the pod address, and `GEOSERVER_CSRF_WHITELIST` lets the web UI
accept logins through the proxy. If layer previews or GetCapabilities URLs
ever point at the wrong host, check those envs first.

## Extensions

Add via env, e.g. `STABLE_EXTENSIONS=css-plugin,importer-plugin` (downloads on
container start, persists in the data dir). List of valid names:
https://github.com/kartoza/docker-geoserver/blob/master/build_data/stable_plugins.txt

## Suite roadmap

- PostGIS (kartoza/postgis) as a proper vector datastore — GeoServer's
  built-in datastores are file-based until then
- NFS read-only mount for raster/shapefile source data from Unraid
