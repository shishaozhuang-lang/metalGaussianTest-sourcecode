#!/bin/zsh
set -euo pipefail

UDID="00008150-0009190E1E21401C"
BUNDLE="com.shichen.metalsplatter.sampleapp"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDER_SECONDS=125
COOLDOWN_SECONDS=60

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# configs: name|model-arg|render-size
CONFIGS=(
  "ply-540|hailuo/point_cloud.ply|540x960"
  "ply-1080|hailuo/point_cloud.ply|1080x1920"
  "morton-540|hailuo/point_cloud_morton.ply|540x960"
  "morton-1080|hailuo/point_cloud_morton.ply|1080x1920"
  "mp4-540|hailuo/point_cloud_morton_spatial_vivid_first_view.mp4|540x960"
  "mp4-1080|hailuo/point_cloud_morton_spatial_vivid_first_view.mp4|1080x1920"
)

launch_and_get_pid() {
  local json
  json=$(xcrun devicectl device process launch \
    --device "$UDID" \
    --terminate-existing \
    --json-output - \
    "$BUNDLE" -- "$@" 2>&1)
  echo "$json" | grep -iE '"processIdentifier"' | grep -oE '[0-9]+' | head -1
}

terminate_pid() {
  xcrun devicectl device process terminate --device "$UDID" --pid "$1" --kill >/dev/null 2>&1 || true
}

pull_docs() {
  local tmp="$1"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  xcrun devicectl device copy from \
    --device "$UDID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" \
    --source Documents \
    --destination "$tmp" >/dev/null 2>&1
}

run_one() {
  local name="$1" model="$2" size="$3"
  local csv_on_device="perf-${name}.csv"
  local csv_out="$OUT_DIR/ios-${name}.csv"

  log "=== 开始 ${name} (${model} @ ${size}) ==="

  # 1. 启动（--terminate-existing 会先杀掉上一轮残留实例）
  local pid
  pid=$(launch_and_get_pid --model "$model" --perf="$csv_on_device" --render-size "$size")
  if [[ -z "$pid" ]]; then
    log "!! ${name}: 启动失败，未拿到 PID"
    return 1
  fi
  log "    ${name}: 已启动 PID=${pid}，渲染 ${RENDER_SECONDS}s…"

  # 2. 渲染等待
  sleep "$RENDER_SECONDS"

  # 3. 关闭应用
  terminate_pid "$pid"
  log "    ${name}: 已关闭 app (PID=${pid})"

  # 4. 拉取 CSV
  local tmp="$OUT_DIR/.tmp-${name}"
  pull_docs "$tmp"
  if [[ -f "$tmp/$csv_on_device" ]]; then
    cp "$tmp/$csv_on_device" "$csv_out"
    local rows=$(( $(wc -l < "$csv_out") - 1 ))
    log "    ${name}: CSV 已保存 (${rows} 帧) → ${csv_out}"
  else
    log "!! ${name}: 设备上找不到 ${csv_on_device}"
  fi
  rm -rf "$tmp"

  # 5. 静置冷却
  log "    ${name}: 静置冷却 ${COOLDOWN_SECONDS}s…"
  sleep "$COOLDOWN_SECONDS"
}

for cfg in "${CONFIGS[@]}"; do
  IFS='|' read -r name model size <<< "$cfg"
  if ! run_one "$name" "$model" "$size"; then
    log "!! ${name} 失败，跳过并继续"
  fi
done

log "全部完成。CSV 输出目录: ${OUT_DIR}"
