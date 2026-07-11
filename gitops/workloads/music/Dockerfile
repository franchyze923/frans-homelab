# Custom spotDL image: the official spotdl/spotify-downloader image is
# Alpine/musl and its tls_client dependency ships a glibc-only Go shared
# library (libresolv + initial-exec TLS relocations), so it crashes on any
# real sync. Debian slim + pip works.
#   podman build -t docker.io/franchyze923/spotdl:4.5.0 .
#   podman push docker.io/franchyze923/spotdl:4.5.0
FROM python:3.13-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir spotdl==4.5.0
ENTRYPOINT ["spotdl"]
