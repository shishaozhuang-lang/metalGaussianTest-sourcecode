#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h}"
cd "$repo_dir"

mkdir -p .cache/clang .tmp
export CLANG_MODULE_CACHE_PATH="$repo_dir/.cache/clang"
export TMPDIR="$repo_dir/.tmp"

swift test --disable-sandbox --scratch-path "$repo_dir/.build" --jobs 4

converter="$repo_dir/.build/arm64-apple-macosx/debug/SplatConverter"
fixture="$repo_dir/SplatIO/TestData/test-splat.3-points-from-train.ply"
"$converter" "$fixture" -o "$repo_dir/.tmp/roundtrip.spz" -f spz -v
"$converter" "$repo_dir/.tmp/roundtrip.spz" -o "$repo_dir/.tmp/roundtrip.ply" -f ply-ascii -v

echo "Verification complete: tests passed and PLY -> SPZ -> PLY round-trip succeeded."
