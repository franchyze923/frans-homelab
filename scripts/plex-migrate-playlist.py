#!/usr/bin/env python3
"""
Plex Playlist Migration Tool

Migrates audio playlists between two Plex servers, handling path differences
and unicode filename normalization.

Requirements:
    pip install plexapi

Usage:
    # List playlists on source server
    python3 plex-migrate-playlist.py --list

    # Migrate a specific playlist
    python3 plex-migrate-playlist.py --playlist "big_playlist"

    # Migrate all audio playlists
    python3 plex-migrate-playlist.py --all

    # Dry run (show what would be matched without creating anything)
    python3 plex-migrate-playlist.py --playlist "Heavy" --dry-run

Environment variables (or edit the defaults below):
    PLEX_SRC_URL    - Source Plex server URL
    PLEX_DST_URL    - Destination Plex server URL
    PLEX_TOKEN      - Plex authentication token
"""

import os
import sys
import argparse
import unicodedata
import re

try:
    from plexapi.server import PlexServer
except ImportError:
    print("Error: plexapi not installed. Run: pip install plexapi")
    sys.exit(1)

# ── Configuration ──────────────────────────────────────────────────────────────
# Edit these defaults or use environment variables

SRC_URL = os.environ.get("PLEX_SRC_URL", "http://192.168.40.232:32400")
DST_URL = os.environ.get("PLEX_DST_URL", "http://192.168.40.201:32400")
TOKEN = os.environ.get("PLEX_TOKEN", "")
TIMEOUT = int(os.environ.get("PLEX_TIMEOUT", "300"))

# Path mappings: (source_prefix, destination_prefix)
# Add entries here if your media is mounted at different paths on each server
PATH_MAPS = [
    ("/FranData/FranMedia/Music", "/media/Music"),
    ("/FranData/FranMedia/metube_youtube_downloader/music", "/media/metube_youtube_downloader/music"),
    ("/FranData/FranMedia/metube_youtube_downloader", "/media/metube_youtube_downloader"),
    ("/FranData/FranMedia", "/media"),
]

# ── Matching Logic ─────────────────────────────────────────────────────────────

def normalize(s):
    """Normalize unicode and lowercase for comparison."""
    return unicodedata.normalize("NFKC", s).lower().strip()


def strip_special(s):
    """Remove all non-alphanumeric chars for fuzzy matching."""
    return re.sub(r'[^\w\s]', '', s)


def find_track_on_dst(item, music_lib, path_maps):
    """Try to find a matching track on the destination server."""
    old_path = ""
    if item.media and item.media[0].parts:
        old_path = item.media[0].parts[0].file

    fname = old_path.rsplit("/", 1)[-1].rsplit(".", 1)[0] if old_path else ""
    fname_norm = normalize(fname)
    title = normalize(item.title or "")

    for term in [item.title[:50] if item.title else "", fname[:30]]:
        if not term or len(term) < 3:
            continue
        try:
            results = music_lib.searchTracks(title=term)
        except Exception:
            continue

        for track in results:
            for media in track.media:
                for part in media.parts:
                    # Strategy 1: exact path mapping
                    for old_prefix, new_prefix in path_maps:
                        if old_path.startswith(old_prefix):
                            expected = old_path.replace(old_prefix, new_prefix, 1)
                            if part.file == expected:
                                return track

                    # Strategy 2: normalized filename match
                    new_fname = part.file.rsplit("/", 1)[-1].rsplit(".", 1)[0]
                    new_norm = normalize(new_fname)
                    if new_norm == fname_norm:
                        return track

                    # Strategy 3: stripped special chars match
                    if strip_special(new_norm) and strip_special(new_norm) == strip_special(fname_norm):
                        return track

    return None


# ── Main ───────────────────────────────────────────────────────────────────────

def migrate_playlist(src, dst, music_lib, playlist_name, dry_run=False):
    """Migrate a single playlist from src to dst."""
    # Find playlist on source
    src_pl = None
    for p in src.playlists():
        if p.title == playlist_name:
            src_pl = p
            break

    if not src_pl:
        print(f"Error: Playlist '{playlist_name}' not found on source server")
        return False

    # Check if it already exists on destination
    dst_pl = None
    for p in dst.playlists():
        if p.title == playlist_name:
            dst_pl = p
            break

    src_items = src_pl.items()
    existing_keys = set()
    if dst_pl:
        existing_keys = set(item.ratingKey for item in dst_pl.items())
        print(f"Playlist '{playlist_name}' already exists on destination with {len(existing_keys)} tracks")

    print(f"Source playlist '{playlist_name}': {len(src_items)} tracks")
    print(f"Matching tracks...")

    matched = []
    not_found = []

    for i, item in enumerate(src_items):
        track = find_track_on_dst(item, music_lib, PATH_MAPS)
        if track and track.ratingKey not in existing_keys:
            matched.append(track)
            existing_keys.add(track.ratingKey)
        elif not track:
            not_found.append(f"  {item.grandparentTitle} - {item.title}")

        if (i + 1) % 25 == 0 or (i + 1) == len(src_items):
            print(f"  [{i+1}/{len(src_items)}] matched {len(matched)} new tracks...")

    print(f"\nResults for '{playlist_name}':")
    print(f"  Matched: {len(matched)} new tracks to add")
    if not_found:
        print(f"  Not found ({len(not_found)}):")
        for s in not_found:
            print(s)

    if dry_run:
        print(f"\n  [DRY RUN] Would have added {len(matched)} tracks")
        return True

    if matched:
        if dst_pl:
            dst_pl.addItems(matched)
            print(f"\n  Added {len(matched)} tracks to existing playlist")
        else:
            dst.createPlaylist(playlist_name, items=matched)
            print(f"\n  Created playlist '{playlist_name}' with {len(matched)} tracks")
    else:
        print(f"\n  No new tracks to add")

    return True


def main():
    parser = argparse.ArgumentParser(description="Migrate Plex audio playlists between servers")
    parser.add_argument("--list", action="store_true", help="List audio playlists on source server")
    parser.add_argument("--playlist", type=str, help="Name of playlist to migrate")
    parser.add_argument("--all", action="store_true", help="Migrate all audio playlists")
    parser.add_argument("--dry-run", action="store_true", help="Show matches without creating playlist")
    parser.add_argument("--src", type=str, default=SRC_URL, help=f"Source server URL (default: {SRC_URL})")
    parser.add_argument("--dst", type=str, default=DST_URL, help=f"Destination server URL (default: {DST_URL})")
    parser.add_argument("--token", type=str, default=TOKEN, help="Plex token (or set PLEX_TOKEN env var)")
    args = parser.parse_args()

    token = args.token
    if not token:
        print("Error: Plex token required. Use --token or set PLEX_TOKEN env var")
        print("\nTo find your token:")
        print("  1. Open Plex web UI")
        print("  2. Open any media item → '...' → 'Get Info' → 'View XML'")
        print("  3. Copy the X-Plex-Token value from the URL")
        sys.exit(1)

    print(f"Connecting to source: {args.src}")
    src = PlexServer(args.src, token, timeout=TIMEOUT)
    print(f"Connecting to destination: {args.dst}")
    dst = PlexServer(args.dst, token, timeout=TIMEOUT)

    if args.list:
        print(f"\nAudio playlists on {args.src}:")
        for p in src.playlists():
            if p.playlistType == "audio":
                print(f"  - {p.title} ({len(p.items())} tracks)")
        return

    # Get music library on destination
    music_lib = None
    for section in dst.library.sections():
        if section.type == "artist":
            music_lib = section
            break

    if not music_lib:
        print("Error: No music library found on destination server")
        sys.exit(1)

    if args.all:
        playlists = [p for p in src.playlists() if p.playlistType == "audio"]
        print(f"\nMigrating {len(playlists)} audio playlists...\n")
        for p in playlists:
            print(f"{'='*60}")
            migrate_playlist(src, dst, music_lib, p.title, args.dry_run)
            print()
    elif args.playlist:
        migrate_playlist(src, dst, music_lib, args.playlist, args.dry_run)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
