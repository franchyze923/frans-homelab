# music — spotDL + Navidrome

Self-hosted music: a nightly **spotDL** CronJob mirrors chosen public Spotify
playlists (metadata from the Spotify API, audio from YouTube Music — same
category of tool as MeTube) into the shared NFS library, and **Navidrome**
(`navidrome.franpolignano.com`) serves it. Subsonic-compatible, so phone apps
like Symfonium / play:Sub work against it.

## Adding playlists

Edit the `spotdl-playlists` ConfigMap in `music.yaml` — one public Spotify
playlist/album/artist URL per line — and push.

**Spotify-generated playlists don't work.** Anything with an ID starting
`37i9dQZF` (Daily Mix, On Repeat, Discover Weekly, editorial lists) has been
blocked for third-party API access by Spotify since Nov 2024; spotdl dies
with `KeyError: 'ownerV2'`. Workaround: in the Spotify app, select-all the
playlist's tracks → Add to playlist → New playlist, make it **public**, and
use that URL. (Personal mixes change weekly, so re-copy when you want the
new tracks.) Next nightly run (03:30) picks
it up; to sync immediately:

```
kubectl -n music create job --from=cronjob/spotdl-sync spotdl-manual-$(date +%s)
```

Layout: `/music/{artist}/{album}/*.mp3` plus one `.m3u8` per playlist in
`/music/playlists/` (Navidrome imports those automatically, rescans hourly).
Sync state lives in `/music/.spotdl/` — delete a playlist's `.spotdl` file to
force a full re-check. spotDL uses its built-in Spotify API credentials; if
rate-limited, create your own app at developer.spotify.com and add
`--client-id`/`--client-secret` to the CronJob command via an out-of-band
Secret (template in this README, NOT in git).

## Storage

| Volume | Where | Backed up? |
|---|---|---|
| `music-library` | NFS `FranData/FranMedia/music` (RWX) | No — re-downloadable |
| `navidrome-data` | Ceph RBD (RWO, SQLite DB + cache) | Nightly 01:45 tar → NFS `FranArchives/k8s-pvs/navidrome`, restore initContainer on fresh PVC |

The backup CronJob has required podAffinity to `app=navidrome` (RWO RBD —
same Multi-Attach lesson as gitea). `spotdl-sync` has
`activeDeadlineSeconds: 21600` so a wedged NFS mount can't block future runs
forever via `Forbid` (see CHANGELOG 2026-07-10); note `nfs-mount-healer` does
NOT watch the `music` namespace.

## First-time setup

- Navidrome shows a "create admin" page on first visit — local account, no
  SSO (Navidrome has no native OIDC; it's on the keycloak README no-SSO list).
- Users/playlists/play counts are in `navidrome-data`, covered by the backup.
