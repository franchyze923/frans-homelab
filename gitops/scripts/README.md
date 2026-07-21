# Plex Playlist Migration Tool

Migrates audio playlists between two Plex servers. Handles different mount paths and unicode filename quirks (fullwidth characters from YouTube titles, etc.).

## Requirements

```bash
pip install plexapi
```

## Getting Your Plex Token

1. Open Plex web UI in a browser
2. Navigate to any media item
3. Click `...` → **Get Info** → **View XML**
4. Copy the `X-Plex-Token=xxxxx` value from the URL

## Usage

```bash
# List all audio playlists on the source server
python3 plex-migrate-playlist.py --list --token YOUR_TOKEN

# Migrate a single playlist
python3 plex-migrate-playlist.py --playlist "Heavy" --token YOUR_TOKEN

# Migrate all audio playlists
python3 plex-migrate-playlist.py --all --token YOUR_TOKEN

# Dry run (preview matches without creating anything)
python3 plex-migrate-playlist.py --playlist "Heavy" --dry-run --token YOUR_TOKEN

# Custom server URLs
python3 plex-migrate-playlist.py --playlist "Heavy" \
  --src http://old-plex:32400 \
  --dst http://new-plex:32400 \
  --token YOUR_TOKEN
```

## Configuration

You can configure defaults by editing the variables at the top of the script or by setting environment variables:

| Env Variable     | Description                    | Default                          |
|------------------|--------------------------------|----------------------------------|
| `PLEX_TOKEN`     | Plex authentication token      | *(none, required)*               |
| `PLEX_SRC_URL`   | Source Plex server URL         | `http://192.168.40.232:32400`    |
| `PLEX_DST_URL`   | Destination Plex server URL   | `http://192.168.40.201:32400`    |
| `PLEX_TIMEOUT`   | API request timeout (seconds) | `300`                            |

### Path Mappings

If media files are mounted at different paths on each server, edit the `PATH_MAPS` list in the script:

```python
PATH_MAPS = [
    ("/old/path/to/Music", "/new/path/to/Music"),
    ("/old/path/to/downloads", "/new/path/to/downloads"),
]
```

## How Matching Works

The tool uses a three-tier matching strategy for each track:

1. **Exact path mapping** — applies `PATH_MAPS` to convert the source path and checks for an exact match on the destination
2. **Normalized filename** — normalizes unicode (e.g. fullwidth `＂` → `"`) and compares filenames case-insensitively
3. **Stripped filename** — removes all special characters and compares alphanumeric content only

---

# GPU Transcode Benchmark

`gpu-transcode-bench.sh` — A/B tests real hardware transcode performance
(NVENC vs VAAPI, or any future card) against the *same* source clip. Built
2026-07-21 comparing the Tesla P4 (`ubuntu24-gpu-box`) against the RX 570
(`ubuntu-26-desktop-node`) after finding the RX 570 can't hardware-encode
10-bit HEVC (Polaris VCE lacks a `VAProfileHEVCMain10` encode entrypoint —
decode-only). Reusable for testing any future card swap (e.g. the 1050 Ti).

Runs two tests — HEVC 10-bit target and H264 target — each fully
hardware-accelerated (decode + scale + encode all on the GPU, no CPU
fallback), reporting wall-clock time, ffmpeg's own reported speed, and
peak GPU utilization sampled during the run. Output is discarded
(`-f null`) so disk I/O isn't a variable.

## Usage

Copy to the target host directly (it needs local `ffmpeg` with the
relevant hwaccel built in, plus `nvidia-smi` for NVENC or a `/sys/class/drm`
render node for VAAPI) and run in place -- this isn't meant to run
centrally against a remote GPU:

```sh
scp gpu-transcode-bench.sh someuser@target-host:/tmp/
ssh someuser@target-host '/tmp/gpu-transcode-bench.sh nvenc /tmp/sample.mkv'   # Nvidia
ssh someuser@target-host '/tmp/gpu-transcode-bench.sh vaapi /tmp/sample.mkv'   # AMD/Intel VAAPI
```

Use a real representative source clip (same file on both hosts for a fair
comparison) -- a ~90s extract via `ffmpeg -ss <offset> -i src.mkv -t 90
-c copy sample.mkv` from an actual library file avoids synthetic-content
bias and keeps each test run under a minute.

## Results so far (2026-07-21)

| Test | Tesla P4 (NVENC) | RX 570 (VAAPI) |
|---|---|---|
| HEVC 10-bit target | OK, ~2x speed, ~25% GPU util | **Fails instantly** -- no HEVC Main10 encode entrypoint |
| H264 target | OK, ~2x speed, ~23% GPU util | OK, **~3.7x speed**, ~53% GPU util |

Takeaway: the P4 is the only one of the two that can do everything: it's
the only card capable of hardware-encoding your 10-bit HEVC (reencoded)
library at all. But for content that *does* transcode to H264 (the more
common case for most non-Apple-TV clients), the RX 570 is faster. Neither
card is a strict upgrade over the other for this workload -- capability
coverage and raw speed favor different cards.

If a playlist already exists on the destination, the tool will only add missing tracks (no duplicates).
