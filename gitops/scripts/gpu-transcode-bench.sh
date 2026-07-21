#!/usr/bin/env bash
# GPU transcode benchmark: runs the same real 1080p 10-bit HEVC source
# through hardware transcode on whichever GPU is local to this host, for
# both an HEVC-target and H264-target output, and reports wall-clock time,
# ffmpeg's own average speed, and peak GPU utilization sampled during the
# run. Output is discarded (-f null) so disk I/O isn't a variable -- this
# measures encode/decode throughput only.
#
# Usage: ./gpu-transcode-bench.sh <nvenc|vaapi> <input.mkv>
set -uo pipefail

MODE="${1:?usage: $0 <nvenc|vaapi> <input.mkv>}"
INPUT="${2:?usage: $0 <nvenc|vaapi> <input.mkv>}"
[ -f "$INPUT" ] || { echo "input file not found: $INPUT" >&2; exit 1; }

gpu_sample_start() {
  SAMPLES=/tmp/gpu-bench-samples.$$
  : > "$SAMPLES"
  (
    while true; do
      if [ "$MODE" = "nvenc" ]; then
        nvidia-smi --query-gpu=utilization.gpu,utilization.encoder,utilization.decoder --format=csv,noheader,nounits 2>/dev/null
      else
        cat /sys/class/drm/card1/device/gpu_busy_percent 2>/dev/null
      fi
      sleep 0.5
    done >> "$SAMPLES"
  ) &
  SAMPLER_PID=$!
}

gpu_sample_stop_and_report() {
  kill "$SAMPLER_PID" 2>/dev/null
  wait "$SAMPLER_PID" 2>/dev/null
  if [ "$MODE" = "nvenc" ]; then
    echo "  peak GPU util:     $(awk -F',' '{gsub(/ /,"",$1); if($1+0>m)m=$1} END{print m"%"}' "$SAMPLES")"
    echo "  peak encoder util: $(awk -F',' '{gsub(/ /,"",$2); if($2+0>m)m=$2} END{print m"%"}' "$SAMPLES")"
    echo "  peak decoder util: $(awk -F',' '{gsub(/ /,"",$3); if($3+0>m)m=$3} END{print m"%"}' "$SAMPLES")"
  else
    echo "  peak GPU busy:     $(awk '{if($1+0>m)m=$1} END{print m"%"}' "$SAMPLES")"
  fi
  rm -f "$SAMPLES"
}

run_test() {
  local label="$1" video_filter="$2" encoder="$3" hwaccel_args="$4"
  echo "=== $label ==="
  gpu_sample_start
  local start end
  start=$(date +%s.%N)
  local ffout
  ffout=$(ffmpeg -y $hwaccel_args -i "$INPUT" \
    -vf "$video_filter" -c:v "$encoder" -preset fast -b:v 8000k -maxrate 8000k -bufsize 16000k \
    -c:a aac -b:a 256k -f null - 2>&1)
  local rc=$?
  end=$(date +%s.%N)
  gpu_sample_stop_and_report
  local wall
  wall=$(awk -v s="$start" -v e="$end" 'BEGIN{printf "%.1f", e-s}')
  echo "  wall clock:        ${wall}s"
  if [ $rc -ne 0 ]; then
    echo "  RESULT: FAILED"
    echo "$ffout" | grep -iE "error|entrypoint|no usable" | tail -3 | sed 's/^/  /'
  else
    local speed
    speed=$(echo "$ffout" | grep -o 'speed=[0-9.]*x' | tail -1)
    echo "  ffmpeg speed:      ${speed:-unknown}"
    echo "  RESULT: OK"
  fi
  echo
}

echo "Host: $(hostname)  |  Mode: $MODE  |  Input: $INPUT"
echo "-----------------------------------------------------------"

if [ "$MODE" = "nvenc" ]; then
  run_test "HEVC 10-bit target (NVENC)" "scale_cuda=1920:1080" "hevc_nvenc" \
    "-hwaccel cuda -hwaccel_output_format cuda"
  run_test "H264 target (NVENC)" "scale_cuda=1920:1080:format=nv12" "h264_nvenc" \
    "-hwaccel cuda -hwaccel_output_format cuda"
elif [ "$MODE" = "vaapi" ]; then
  run_test "HEVC 10-bit target (VAAPI)" "scale_vaapi=w=1920:h=1080:format=p010" "hevc_vaapi" \
    "-hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi"
  run_test "H264 target (VAAPI)" "scale_vaapi=w=1920:h=1080:format=nv12" "h264_vaapi" \
    "-hwaccel vaapi -hwaccel_device /dev/dri/renderD128 -hwaccel_output_format vaapi"
else
  echo "unknown mode: $MODE (expected nvenc or vaapi)" >&2
  exit 1
fi
