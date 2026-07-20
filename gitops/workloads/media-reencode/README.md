# media-reencode

Standing worker that gradually re-encodes fat H.264/legacy video to x265
(HEVC 10-bit), reclaiming space on the Unraid pool. Born from the 2026-07-15
library review: ~2.1 TB of oversized H.264 TV + a handful of 10–29 Mbps
movies, expected to shrink to roughly half.

## Scope — what it will and won't touch
- **TV episodes** (Plex section 4): legacy codec AND bitrate > 8 Mbps
  (1080p+), > 5 Mbps (720p), or > 3 Mbps (SD). CRF 23, preset fast
  (~35% quicker than medium for ~5% larger output — right trade for TV).
- **Movies** (section 3): legacy codec AND ≥ 9.5 Mbps — only the fattest.
  CRF 20, preset slow (higher quality bar).
- **Never**: home videos / other sections (irreplaceable originals — decided
  2026-07-15), anything already HEVC/AV1/VP9, any path outside `/media`.

Candidates come from the Plex API at runtime (biggest file first), so no
media filenames live in this repo. Audio and subtitle streams are copied
untouched (`mov_text` converted to srt for the mkv container); output is
always `.mkv` with the same basename, so Plex/Sonarr/Radarr re-associate on
rescan and watch state survives.

## Safety model
1. Encode to a temp file on the same NFS share (`/media/.reencode/tmp`).
2. Verify: duration within 2%+5s of source, head+tail decode cleanly,
   output strictly smaller.
3. Replace without a gap: same-name mkv is an atomic rename-over; otherwise
   the new file lands first, then the original is removed. A failed `mv`
   never deletes the source.
4. Trigger a partial Plex scan of just that directory.

State lives on the share in `/media/.reencode/` (`done.log`, `skip.log`,
`fail.log`) — pod restarts resume where they left off. Replicas coordinate
via lock dirs on the share: `mkdir` is the atomic claim, a background
heartbeat touches owned locks every 60s, and a lock untouched for 15 min is
treated as a dead pod's and taken over. Scale with `replicas:` freely;
pod anti-affinity pins one worker per node.

## Operations
- **Pause/resume**: `./toggle.sh off` / `./toggle.sh on` / `./toggle.sh status`.
  Wraps `kubectl exec` to touch/remove `/media/.reencode/pause` on whichever
  worker pod is running -- checked between files, so a pause finishes the
  file currently encoding before the worker idles. Equivalent by hand:
  `touch /media/.reencode/pause` (`rm` to resume) from any pod with the
  share mounted, or Unraid itself (`/mnt/user/FranData/FranMedia/.reencode/pause`).
- **Progress**: `kubectl logs -n media-reencode deploy/media-reencode`
  — one `DONE saved <n> MB` line per file — or `wc -l done.log`.
- **Re-queue a failed file**: remove its line from `fail.log`.
- **Script changes**: the ConfigMap updates in place but the running pod
  keeps the old script — `kubectl rollout restart deploy/media-reencode
  -n media-reencode` after sync.
- Runs on amd64 non-GPU nodes (nodeAffinity keeps it off the GPU box so
  it never competes with Plex/Frigate/ollama). 3 replicas, one per node,
  each requesting 2 CPU / capped at 8. Estimated **~10–14 days** for the
  initial TV backlog; still a polite background grind per node.

## Secret (out-of-band, NOT in git)
`media-reencode-secrets` carries the Plex token the worker uses to query the
library and trigger rescans. Apply manually; do **not** add a Secret manifest
to this directory (ArgoCD would apply it — see the immich incident):

```sh
kubectl create secret generic media-reencode-secrets -n media-reencode \
  --from-literal=PLEX_TOKEN=<token>
```

Get the token: `gitops/workloads/plex/README.md` documents grepping
`PlexOnlineToken` from Preferences.xml in the plex pod. If the token is ever
rotated (Plex account password change), recreate this secret.

## Encode settings rationale
x265 10-bit (`yuv420p10le`) — better compression and less banding, decodes
everywhere modern HEVC does (Main10 is in every hw decoder profile, incl.
the P4). `yadif=deint=interlaced` deinterlaces only frames flagged
interlaced (old SD sources) and passes progressive content through. CPU
x265 over P4 NVENC was deliberate: Pascal NVENC needs ~30% more bitrate for
the same quality, and the GPU is already time-sliced three ways.
