# hamclock — ham radio wall dashboard

[HamClock](https://www.clearskyinstitute.com/ham/HamClock/) by Elwood Downey
(WB0OEW, SK): solar/space weather, band conditions, VOACAP propagation maps,
DX cluster spots, satellite passes — all on one map. No radio hardware needed;
everything is fed from the internet.

- **URL:** <https://hamclock.franpolignano.com>
- **Image:** [`ggilman/hamclock`](https://hub.docker.com/r/ggilman/hamclock)
  (multi-arch, non-root, healthchecked)
- **Backend:** defaults to the `hamclock.com` community backend (W4BAE).
  The original `clearskyinstitute.com` backend shut down June 2026, so never
  set `BACKEND_PRESET=original`.

## First-time setup

Open the URL and walk the on-screen setup: callsign (or `NOCALL` until the
license arrives), DE location (grid square or lat/long), then pick panes.
Everything persists on the `hamclock-config` PVC.

## Notes

- Resolution is the container *command arg* (`hamclock-1600x960` in the
  manifest). Options: 800x480 / 1600x960 / 2400x1440 / 3200x1920 — bigger
  costs more CPU for the render loop.
- The web UI is a live view of a single shared canvas: every browser tab
  sees (and controls) the same clock. That's by design — it's a wall
  dashboard, not a multi-user app.
- The real UI path is `/live.html`; the HTTPRoute redirects bare `/`
  there (HamClock's web server 400s on `/`).
