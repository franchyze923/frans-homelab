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

## PostGIS (`postgis.yaml`)

`postgis/postgis:17-3.5` in the same namespace — internal-only vector
datastore (host `postgis`, db/user `gis`). Data on Ceph RBD; nightly
`pg_dump` at 03:30 to the shared NFS backup volume
(`postgis-gis.sql.gz`). Password in Secret `postgis-credentials`
(out-of-band, NOT in git; plaintext in `cluster/postgis-credentials.txt`).
Template:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgis-credentials
  namespace: geoserver
type: Opaque
stringData:
  POSTGRES_PASSWORD: "REPLACE_ME"
```

Restore after rebuild (data dir re-inits empty from env, then):

```sh
kubectl -n geoserver exec -i deploy/postgis -- sh -c \
  'gunzip | psql -U gis -d gis' < postgis-gis.sql.gz
```

GeoServer is wired to it already: workspace `strava`, datastore `postgis`
(created via REST; lives in the geoserver data dir, so it's covered by the
geoserver backup). If rebuilt from scratch without a backup, recreate the
workspace/datastore in the UI or via REST.

## Strava tracks (GPX → PostGIS → WMS/WFS)

Table `strava_tracks` (MultiLineString, EPSG:4326) is published as layer
`strava:strava_tracks`. Load GPX files with:

```sh
./load-gpx.sh ~/Downloads/strava-export/activities/   # dir or single .gpx
```

The script port-forwards PostGIS and runs `ogr2ogr` (GDAL container via
podman) against each file's `tracks` layer, appending to `strava_tracks`.
Quick view: layer preview in the GeoServer UI, or
https://geoserver.franpolignano.com/geoserver/strava/wms?service=WMS&version=1.3.0&request=GetMap&layers=strava:strava_tracks&crs=EPSG:4326&bbox=-90,-180,90,180&width=1024&height=512&format=application/openlayers

Getting the GPX files out of Strava:

- **Bulk export** (easiest, all history): strava.com → Settings → My Account
  → "Download or Delete Your Account" → "Download Request". Email arrives
  with a zip; `activities/` holds the files. NOTE: rides recorded on
  devices upload as `.fit.gz`, not GPX — convert with
  `gpsbabel -i garmin_fit -f x.fit -o gpx -F x.gpx` or load FIT directly
  (GDAL has no FIT driver, so convert first).
- **Per-activity**: activity page → ⋯ → "Export GPX" (always GPX).
- **API**: automated via the `strava-sync` CronJob below.

## Daily API sync (`strava-sync.yaml`)

CronJob `strava-sync` (05:00) pulls new activities from the Strava API into
table `strava_activities`, published as layer `strava:strava_activities`
(full-res GPS from the streams API; trainer/manual rides get the summary
polyline or a NULL geom). Pipeline: psql reads state → stdlib-only python
(no pip) fetches + writes SQL → psql applies. No custom image.

One-time setup:

1. Create an API app at https://www.strava.com/settings/api
   (Authorization Callback Domain: `localhost`).
2. `./strava-auth.sh` — does the OAuth dance and creates Secret `strava-api`
   (client id/secret + first refresh token; also writes
   `cluster/strava-credentials.txt`, gitignored). Until this is done the
   daily job fails fast — `activeDeadlineSeconds` keeps a stuck pod from
   blocking later runs.
3. First sync / backfill: runs are capped at 100 activities (env
   `MAX_ACTIVITIES_PER_RUN`) to respect Strava rate limits (100 req/15min,
   1000/day), resuming where they left off. Backfill faster by re-running:
   `kubectl -n geoserver create job --from=cronjob/strava-sync strava-sync-2`

**Token rotation:** Strava rotates refresh tokens on every refresh (same
trap as Withings). The live token lives in the `strava_auth` table — NOT in
the Secret, which only seeds the first run — so it's inside the nightly
`pg_dump` and survives rebuilds. Never run two sync jobs concurrently
(`concurrencyPolicy: Forbid` enforces this).

## Suite roadmap

- NFS read-only mount for raster/shapefile source data from Unraid
- Style the activities layer (SLD) + a small web map frontend
