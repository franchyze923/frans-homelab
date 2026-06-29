# Frigate secret (applied out-of-band)

The camera/RTSP passwords are **not** in git. They live in a Secret named
`frigate-secrets` that you apply manually — ArgoCD does not manage it.

> **Important:** do not commit a real Secret manifest into this directory. ArgoCD
> syncs every `.yaml`/`.yml`/`.json` here and will apply it, so a committed
> Secret (even an "example") overwrites the real one. That's why this template
> lives in a `.md` file, and the real `secret.yaml` is gitignored.

## Apply / update

```sh
# edit workloads/frigate/secret.yaml (gitignored) with the real values, then:
kubectl apply -f workloads/frigate/secret.yaml
kubectl rollout restart deploy/frigate -n frigate   # pick up new env values
```

## Secret shape

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: frigate-secrets
  namespace: frigate
type: Opaque
stringData:
  # Internal go2rtc/restream RTSP server password.
  FRIGATE_RTSP_PASSWORD: "REPLACE_ME"
  # Reolink camera (.198) password -- {FRIGATE_REOLINK_PASSWORD} in config.yaml.
  FRIGATE_REOLINK_PASSWORD: "REPLACE_ME"
  # Second Reolink (.6) password -- {FRIGATE_REOLINK2_PASSWORD}. URL-ENCODE any
  # special chars (this camera's password has a '#', stored as %23). See below.
  FRIGATE_REOLINK2_PASSWORD: "REPLACE_ME"
```

## ⚠️ Gotcha: passwords with special characters must be URL-encoded

Camera passwords get injected into go2rtc **stream URLs** (RTSP / HTTP-FLV), so
any character that's special in a URL **breaks the stream** unless it's
URL-encoded in the secret. The classic offender is **`#`** — it's both a URL
fragment delimiter *and* go2rtc's own option separator (`#video=copy`...), so a
password like `i6om6#dP` silently truncates to `i6om6`, and the camera rejects it
(`Error opening input ... Invalid data found when processing input`).

Store the password **URL-encoded** in the secret:

| char | store as | | char | store as |
|---|---|---|---|---|
| `#` | `%23` | | `:` | `%3A` |
| `@` | `%40` | | `/` | `%2F` |
| `?` | `%3F` | | `%` | `%25` |

e.g. password `i6om6#dP` → `FRIGATE_REOLINK2_PASSWORD: "i6om6%23dP"`. The encoded
value works for both RTSP and HTTP-FLV URLs (the camera decodes it server-side).

## Gotcha: not all Reolinks serve the HTTP-FLV/BCS API

The `.198` camera streams via Reolink's HTTP-FLV API
(`ffmpeg:http://<ip>/flv?...app=bcs...`). The `.6` camera does **not** (it 404s /
"Invalid data") — use **RTSP** instead:
`rtsp://<user>:{FRIGATE_<CAM>_PASSWORD}@<ip>:554/h264Preview_01_main` (main) or
`.../h264Preview_01_sub` (sub). Point the camera's `detect` role at the **sub**
stream so Frigate's capture gets frames without a `No frames received` watchdog
loop. For a **view-only** camera, set `detect`, `record`, and `snapshots` all to
`enabled: false`.
