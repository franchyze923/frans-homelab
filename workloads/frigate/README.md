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
  # Reolink camera password -- referenced in config.yaml as {FRIGATE_REOLINK_PASSWORD}.
  FRIGATE_REOLINK_PASSWORD: "REPLACE_ME"
```
