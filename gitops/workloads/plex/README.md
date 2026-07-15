# plex

Plex Media Server (linuxserver image), pinned to the GPU node (`gpu: "true"`,
Tesla P4) for NVENC/NVDEC hardware transcoding.

## Storage
- **Ceph RBD** (`plex-config`, RWO): `/config` — Plex app data + SQLite DB.
  RWO on RBD is why the Deployment uses `Recreate` (avoids Multi-Attach
  deadlocks on node moves).
- **NFS** (`plex-media`, `plex-homemedia`, `plex-familymedia`): media, read-only.
- **NFS** (`plex-config-backup`): 6-hourly config tarball target; the
  `restore-config` init container auto-restores `/config` from it when empty.
- **tmpfs** (`transcode`, emptyDir `medium: Memory`, `sizeLimit: 8Gi`):
  `/transcode` — RAM-backed transcode scratch. See below.

## RAM-backed transcode dir (added 2026-07-15)

Transcode segments used to land on the Ceph config PVC (Plex's default when
"Transcoder temporary directory" is unset) — constant small writes for
throwaway data. Now they go to an 8Gi tmpfs at `/transcode`.

Two halves, and both are required:

1. **Manifest** (`plex.yaml`): the `transcode` emptyDir with `medium: Memory`
   mounted at `/transcode`. tmpfs usage counts against the container's 16Gi
   memory limit; exceeding `sizeLimit` gets the pod **evicted** (it restarts,
   active streams drop briefly). Sized against the node: 32Gi allocatable,
   ~5Gi in typical use.
2. **Plex preference**: `TranscoderTempDirectory=/transcode`. This lives in
   `Preferences.xml` on the config PVC (NOT in git — survives restarts and is
   captured by the config backup). Set via the local API, no restart needed:

   ```sh
   kubectl exec -n plex deploy/plex -- sh -c '
     TOKEN=$(grep -o "PlexOnlineToken=\"[^\"]*\"" \
       "/config/Library/Application Support/Plex Media Server/Preferences.xml" \
       | cut -d\" -f2)
     curl -fsS -X PUT "http://localhost:32400/:/prefs?TranscoderTempDirectory=/transcode&X-Plex-Token=$TOKEN"'
   ```

   The same pattern sets any server preference; also applied:
   `TranscoderThrottleBuffer=300` (default 60) — transcodes buffer 5 min ahead
   so seeks within that window are instant. RAM cost is bounded by the buffer
   (~750MB at a heavy 20 Mbps), well inside the 8Gi cap.

> Plex's own setting description warns against a RAM disk. That warning targets
> undersized tmpfs setups and the DVR/"Optimize versions" features, which write
> whole files through the temp dir. Neither is in use here (verified: no DVRs,
> no sync items). If DVR or Optimize is ever enabled, drop `medium: Memory`
> from the `transcode` volume — a plain emptyDir on the node's local disk keeps
> the churn off Ceph without the size ceiling.

### Verifying it works
Force a transcode via the API (no client needed) and watch the tmpfs:

```sh
# inside the pod, with $TOKEN as above — starts an HLS transcode session:
curl -fsS "http://localhost:32400/video/:/transcode/universal/start.m3u8?hasMDE=1&path=%2Flibrary%2Fmetadata%2F<ratingKey>&mediaIndex=0&partIndex=0&protocol=hls&directPlay=0&directStream=0&maxVideoBitrate=2000&videoResolution=1280x720&session=test&X-Plex-Client-Identifier=test&X-Plex-Product=Plex%20Web&X-Plex-Platform=Chrome&X-Plex-Token=$TOKEN"
# fetch session/test/base/index.m3u8 (same URL prefix) to kick the transcoder, then:
du -sh /transcode        # segments appear under Transcode/Sessions/
# stop + auto-cleanup:
curl -fsS "http://localhost:32400/video/:/transcode/universal/stop?session=test&X-Plex-Token=$TOKEN"
```

Verified 2026-07-15: segments land in tmpfs, NVDEC in use, old Ceph path
untouched, cleanup on stop returns `/transcode` to 0.
