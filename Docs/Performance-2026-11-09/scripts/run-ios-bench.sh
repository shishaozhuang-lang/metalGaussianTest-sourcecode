#!/bin/zsh
set -euo pipefail

UDID="00008150-0009190E1E21401C"
BUNDLE="com.shichen.metalsplatter.sampleapp"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAMES=300
COOLDOWN_SECONDS=30

log() { echo "[$(date '+%H:%M:%S')] $*"; }

CONFIGS=(
  "ply-540|hailuo/point_cloud.ply|540x960"
  "ply-1080|hailuo/point_cloud.ply|1080x1920"
  "morton-540|hailuo/point_cloud_morton.ply|540x960"
  "morton-1080|hailuo/point_cloud_morton.ply|1080x1920"
  "mp4-540|hailuo/point_cloud_morton_spatial_vivid_first_view.mp4|540x960"
  "mp4-1080|hailuo/point_cloud_morton_spatial_vivid_first_view.mp4|1080x1920"
)

RESULTS="$OUT_DIR/bench-results.txt"
: > "$RESULTS"

run_one() {
  local name="$1" model="$2" size="$3"
  log "=== 开始 ${name} (${model} @ ${size}) ==="

  local out
  out=$(xcrun devicectl device process launch \
    --device "$UDID" \
    --console \
    --terminate-existing \
    "$BUNDLE" -- \
    --model "$model" --benchmark-frames="$FRAMES" --render-size "$size" 2>&1) || true

  local line
  line=$(printf '%s\n' "$out" | grep -oE "BENCH-RESULT:.*" | tail -1)
  if [[ -z "$line" ]]; then
    log "!! ${name}: 未捕获到 BENCH-RESULT"
    echo "${name}: ERROR (no result)" >> "$RESULTS"
  else
    log "    ${name}: ${line}"
    echo "${name}: ${line}" >> "$RESULTS"
  fi

  log "    ${name}: 静置冷却 ${COOLDOWN_SECONDS}s…"
  sleep "$COOLDOWN_SECONDS"
}

for cfg in "${CONFIGS[@]}"; do
  IFS='|' read -r name model size <<< "$cfg"
  run_one "$name" "$model" "$size"
done

log "全部完成。结果: ${RESULTS}"
