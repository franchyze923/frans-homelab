#!/usr/bin/env bash
# Load GPX files (e.g. Strava exports) into PostGIS table strava_tracks,
# already published in GeoServer as layer strava:strava_tracks.
#
# Usage: ./load-gpx.sh <file.gpx | dir-with-gpx> [more ...]
#
# Needs: kubectl (homelab kubeconfig), podman, cluster/postgis-credentials.txt
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$HOME/repos/k8s-fun/kubeconfig}"
PGPASS=$(grep '^password:' "$REPO_ROOT/cluster/postgis-credentials.txt" | cut -d' ' -f2)
GDAL_IMAGE=ghcr.io/osgeo/gdal:ubuntu-small-latest
LOCAL_PORT=15432

# Collect .gpx files from args (files or directories)
FILES=()
for arg in "$@"; do
  if [ -d "$arg" ]; then
    while IFS= read -r -d '' f; do FILES+=("$f"); done \
      < <(find "$arg" -name '*.gpx' -print0)
  elif [ -f "$arg" ]; then
    FILES+=("$arg")
  else
    echo "skip: $arg (not found)" >&2
  fi
done
[ ${#FILES[@]} -gt 0 ] || { echo "usage: $0 <file.gpx|dir> [...]" >&2; exit 1; }

kubectl -n geoserver port-forward svc/postgis ${LOCAL_PORT}:5432 >/dev/null &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null' EXIT
for i in $(seq 1 20); do
  (exec 3<>/dev/tcp/127.0.0.1/${LOCAL_PORT}) 2>/dev/null && break
  sleep 0.5
done

loaded=0
for f in "${FILES[@]}"; do
  dir=$(cd "$(dirname "$f")" && pwd)
  base=$(basename "$f")
  echo "loading: $f"
  podman run --rm --network=host -v "$dir":/gpx:ro,Z "$GDAL_IMAGE" \
    ogr2ogr -f PostgreSQL \
    "PG:host=127.0.0.1 port=${LOCAL_PORT} dbname=gis user=gis password=${PGPASS}" \
    "/gpx/$base" tracks -nln strava_tracks -lco GEOMETRY_NAME=geom -append
  loaded=$((loaded+1))
done

echo "done: $loaded file(s) loaded into strava_tracks"
echo "view: https://geoserver.franpolignano.com/geoserver/strava/wms?service=WMS&version=1.3.0&request=GetMap&layers=strava:strava_tracks&crs=EPSG:4326&bbox=-90,-180,90,180&width=1024&height=512&format=application/openlayers"
