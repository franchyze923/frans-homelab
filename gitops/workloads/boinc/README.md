# boinc — idle-compute donation to astronomy projects

BOINC clients that soak up idle CPU on `worker-1`, `worker-2`,
`ubuntu-26-desktop-node`, and `mac-m1-worker` (arm64, separate `boinc-arm`
StatefulSet) for astronomy volunteer-computing projects:

| Project | Science | Sign up |
|---|---|---|
| Einstein@Home | Gravitational waves, pulsars | <https://einsteinathome.org/> |
| MilkyWay@home | Milky Way structure/history | <https://milkyway.cs.rpi.edu/milkyway/> |
| Asteroids@home | Asteroid shape/spin inversion | <https://asteroidsathome.net/boinc/> |

Design notes (yield model, node placement rationale, BOINC-level throttles)
are in the header comment of `boinc.yaml`.

## One-time setup: account keys

1. Create an account on each project site you want (any subset is fine).
2. Grab the **account key** from the account page (`Your account → Account keys`
   on most BOINC sites — the *weak* account key also works and is safer).
3. Create the Secret out-of-band (never committed; `**/secret.yaml` is
   gitignored anyway):

   ```sh
   kubectl -n boinc create secret generic boinc-secrets \
     --from-literal=EINSTEIN_ACCOUNT_KEY='...' \
     --from-literal=MILKYWAY_ACCOUNT_KEY='...' \
     --from-literal=ASTEROIDS_ACCOUNT_KEY='...'
   kubectl -n boinc rollout restart statefulset boinc   # pick up the new env
   ```

Missing keys are fine — the attach sidecar just skips that project. The same
sidecar re-checks every 10 minutes, so a newly-attached project starts pulling
work without further intervention.

## Day-2 ops

```sh
# what is it crunching right now (per pod)
kubectl -n boinc exec boinc-0 -c client -- sh -c 'cd /var/lib/boinc && boinccmd --get_tasks | grep -E "name|fraction|state"'

# project status / credit
kubectl -n boinc exec boinc-0 -c client -- sh -c 'cd /var/lib/boinc && boinccmd --get_project_status'

# pause / resume everything on one pod
kubectl -n boinc exec boinc-0 -c client -- sh -c 'cd /var/lib/boinc && boinccmd --set_run_mode never'
kubectl -n boinc exec boinc-0 -c client -- sh -c 'cd /var/lib/boinc && boinccmd --set_run_mode auto'
```

- **Less power draw**: scale replicas down (`3 → 1 → 0`) in `boinc.yaml`, or
  lower `max_ncpus_pct` in the ConfigMap (applies within ~10 min, no restart).
- **More donation**: raise `max_ncpus_pct` (watch temps on the Ryzen Proxmox
  host — desktop-node lives there).
- **Per-node tuning**: the sidecar prefers
  `global_prefs_override.<nodeName>.xml` from the ConfigMap over the shared
  default. worker-1 (59% of 12) and worker-2 (88% of 8) both land on 7 cores,
  so the two workers match and each roughly keeps pace with the Ryzen
  desktop-node (4 cores, ~1.8× faster per core). Desktop and the M1 use the
  50% default.
- Scaling to 0 abandons in-flight work units after their deadline passes;
  the small work buffer keeps that loss minor. Prefer `--set_run_mode never`
  for short pauses.
- Stats/credit: <https://www.boincstats.com/> aggregates across projects
  (hosts show up as `boinc-0/1/2` and `boinc-arm-0`).
- The M1 pod is `boinc-arm-0` — same commands as above, just swap the pod
  name. Only Einstein@Home publishes aarch64 apps (BRP4 pulsar search), so
  MilkyWay/Asteroids keys are ignored there even once configured.

## Later / not done

- **GPU crunching** (Einstein@Home OpenCL on `ubuntu24-gpu-box`): needs the
  `boinc/client:nvidia` image variant + an `nvidia.com/gpu` resource claim,
  which would monopolize the GPU that Plex/Frigate/ollama share — skipped
  until GPU time-slicing is worth setting up.
