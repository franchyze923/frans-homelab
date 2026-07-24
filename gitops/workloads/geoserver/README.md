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

CronJob `strava-sync` (16:00 America/New_York) pulls new activities from the
Strava API into two tables (full-res GPS from the streams API; trainer/manual
rides get the summary polyline or a NULL geom):

- `strava_activities` — published as `strava:strava_activities`: geometry +
  name, sport_type, start_date, distance, times, elevation gain, avg/max
  speed, avg/max HR, avg watts, kudos, photos (jsonb array of CDN urls,
  largest size returned; only fetched when the activity summary reports
  `total_photo_count > 0`, to avoid a per-activity API call on the common
  case of no photos).
- `strava_activity_data` — NOT published (would bloat WFS): `raw` jsonb =
  the complete API summary (query anything: `raw->>'suffer_score'`), and
  `streams` jsonb = per-point time/altitude/heartrate/cadence/watts/
  velocity/temp/grade along the track. Join `USING (id)`.

Pipeline: psql bootstraps schema + reads state → stdlib-only python (no pip)
fetches + writes SQL → psql applies (upserts). No custom image. After adding
columns, refresh GeoServer's schema cache: `POST /geoserver/rest/reset`.

**Backfilling a new column for already-synced activities:** the hourly job
only lists activities `after` the newest `start_date` already in the table
(see `read-state` init container), so a brand-new column (e.g. `photos`)
never gets backfilled for old rows on its own — only activities synced going
forward get it. To backfill: an ad hoc one-off `Job` (not a git-tracked
manifest — same "ad hoc, not in git" convention as the
`kubectl create job --from=cronjob/strava-sync` backfill above), reusing the
sync job's init-container pattern (psql reads `strava_auth`'s refresh token +
a candidate id list, python does the OAuth refresh + per-activity API calls
and writes `UPDATE` SQL, psql applies it). Critically it must persist the
rotated refresh token back into `strava_auth` even though it's not the
regular sync job — otherwise the next hourly run's token is stale. Capped
per run like the main sync, safe to rerun until the candidate count hits 0.
Done for `photos` on 2026-07-24: 150 activities had `total_photo_count > 0`,
all backfilled across two capped runs.

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

## Strava Globe (`strava-globe.yaml`) — https://tracks.franpolignano.com

Cesium.js 3D viewer for the activities. Static page (ConfigMap) on stock
nginx; no custom image. nginx proxies `/geoserver/` to the in-cluster
service so the browser sees one origin (no CORS). Feeds on
`strava:strava_activities_globe`, a `ST_SimplifyPreserveTopology(geom,
0.00005)` view (~5x smaller payload; full-res geometry stays in
`strava_activities`). Cesium + OSM tiles come from CDNs (no ion token —
add one + world terrain later if 3D relief is wanted). Clicking a track
shows its infoBox; if the activity has photos they render as a thumbnail
strip that links out to the full-size Strava CDN image.

**Manual step after adding a column to `strava_activities`** (e.g. `photos`):
`strava_activities_globe` is a plain PostgreSQL view (`\d+
strava_activities_globe` / `pg_get_viewdef`), not a GeoServer virtual table —
GeoServer just introspects it, so there's no GeoServer-side SQL to edit.
Update it directly against `postgis`:

```sql
CREATE OR REPLACE VIEW strava_activities_globe AS
SELECT id, name, sport_type, start_date, distance_m, moving_time_s,
       elapsed_time_s, elev_gain_m, avg_speed_ms, max_speed_ms, avg_hr,
       max_hr, avg_watts, kudos,
       ST_SimplifyPreserveTopology(geom, 0.00005)::geometry(LineString,4326) AS geom,
       <new_column>
FROM strava_activities;
```

`CREATE OR REPLACE VIEW` only allows new output columns appended at the
*end* of the SELECT list (Postgres rejects reordering/inserting), so new
columns land after `geom` regardless of where they sit in the table. Then
tell GeoServer to pick up the new attribute and drop its cache:

```sh
curl -u admin:<pw> -X PUT \
  ".../rest/workspaces/strava/datastores/postgis/featuretypes/strava_activities_globe?recalculate=nativebbox,attributes" \
  -H "Content-type: text/xml" -d '<featureType><name>strava_activities_globe</name></featureType>'
curl -u admin:<pw> -X POST ".../rest/reset"
```

Done for `photos` on 2026-07-24 (verified via WFS GetFeature that the
`photos` property comes back as a JSON-encoded string array).

Gotchas learned:
- subPath ConfigMap mounts don't live-update: bump the
  `checksum/config` annotation in the same commit as any html/conf change.
- Don't use `clampToGround` polylines: no terrain to drape on, and ground
  polylines crash limited-WebGL clients.
- Track colors are a CVD-validated categorical palette, fixed
  sport→color mapping (Run blue, Ride aqua, Walk yellow, Hike green,
  Swim violet, Other gray).

## Suite roadmap

- NFS read-only mount for raster/shapefile source data from Unraid
- Cesium ion token + world terrain for 3D relief under the tracks
- SLD styling for the WMS side (QGIS/GeoServer previews)
