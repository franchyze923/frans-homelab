# wavelog — amateur radio logbook

[Wavelog](https://www.wavelog.org/) (actively maintained Cloudlog fork):
QSO logging, LoTW / QRZ / Clublog / eQSL sync, award tracking, station map.

- **URL:** <https://wavelog.franpolignano.com>
- **Images:** `ghcr.io/wavelog/wavelog:latest` + `mariadb:11.8`

## One-time setup

1. Create the DB Secret out-of-band (never committed; password also mirrored
   in `cluster/wavelog-credentials.txt`, gitignored):

   ```sh
   kubectl -n wavelog create secret generic wavelog-secrets \
     --from-literal=MARIADB_PASSWORD='...'
   ```

2. Once both pods are Running, open
   <https://wavelog.franpolignano.com/install> and fill in:
   - DB hostname: `wavelog-db` (the Service name — not localhost)
   - Database / username: `wavelog` / `wavelog`
   - Password: from the Secret
   The installer writes `config.php` into the `wavelog-data` PVC and won't
   run again once that file exists.

3. Create the admin account when prompted, then set callsign + station
   profile under Account. `NOCALL`-style placeholder is fine until the
   license/callsign arrives.

## Notes

- MariaDB root password is randomized (`MARIADB_RANDOM_ROOT_PASSWORD`);
  the app only ever uses the `wavelog` user.
- The `wavelog-data` PVC holds `config` / `uploads` / `userdata` subdirs
  (mirrors the upstream compose volumes). The QSO log itself lives in the
  `wavelog-db-data` PVC — that's the one worth backing up once real
  contacts are in it (no backup CronJob yet; see family-tree photos for
  the same gap).
- Upgrades: new `ghcr.io/wavelog/wavelog` images run DB migrations on
  first request after a pod restart.
