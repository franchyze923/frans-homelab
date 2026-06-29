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

If a playlist already exists on the destination, the tool will only add missing tracks (no duplicates).
