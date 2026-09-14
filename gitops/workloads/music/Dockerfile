# Custom spotDL image: the official spotdl/spotify-downloader image is
# Alpine/musl and its tls_client dependency ships a glibc-only Go shared
# library (libresolv + initial-exec TLS relocations), so it crashes on any
# real sync. Debian slim + pip works.
#
# Deno is required: since ~2026-08 YouTube serves player JS challenges that
# yt-dlp must execute in a JS runtime, otherwise every new download fails with
# "Some YouTube downloads require Deno". Bake it in rather than relying on
# `spotdl --download-deno` at runtime (the job pod is ephemeral).
#
#   podman build -t docker.io/franchyze923/spotdl:4.5.2 gitops/workloads/music
#   podman push docker.io/franchyze923/spotdl:4.5.2
FROM docker.io/denoland/deno:bin AS deno

FROM docker.io/python:3.13-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*
COPY --from=deno /deno /usr/local/bin/deno
# Pin spotdl; let pip resolve the newest yt-dlp it allows (YouTube changes
# often, so rebuild this image when downloads start failing again).
RUN pip install --no-cache-dir spotdl==4.5.2 \
    && pip install --no-cache-dir --upgrade "yt-dlp[default]"
ENTRYPOINT ["spotdl"]
