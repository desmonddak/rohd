#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
plugin_dir="$script_dir/plugin"
analysis_options="$repo_root/analysis_options.yaml"
iterations="${1:-3}"
output="${2:-$script_dir/results/latest.txt}"
dart_bin="${DART_BIN:-dart}"

if ! [[ "$iterations" =~ ^[1-9][0-9]*$ ]]; then
  echo "iterations must be a positive integer" >&2
  exit 64
fi

mkdir -p "$(dirname "$output")"
output="$(cd "$(dirname "$output")" && pwd)/$(basename "$output")"
original_options="$(mktemp)"
native_options="$(mktemp)"
fresh_cache="$(mktemp -d)"

cleanup() {
  cp "$original_options" "$analysis_options"
  rm -f "$original_options" "$native_options"
  rm -rf "$fresh_cache"
}
trap cleanup EXIT

cp "$analysis_options" "$original_options"
sed '/^plugins:$/,/^$/d' "$original_options" >"$native_options"

exec > >(tee "$output") 2>&1

run_analyze() {
  local label="$1"
  shift
  echo
  echo "=== $label ==="
  TIMEFORMAT='elapsed_seconds=%3R user_seconds=%3U system_seconds=%3S'
  time "$dart_bin" analyze --fatal-infos "$@"
}

cd "$repo_root"
echo "ROHD analyzer plugin cache reproduction"
echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "commit=$(git rev-parse HEAD)"
echo "platform=$(uname -a)"
"$dart_bin" --version
echo "iterations=$iterations"

echo
echo "Resolving dependencies..."
"$dart_bin" pub get
(cd "$plugin_dir" && "$dart_bin" pub get)

cp "$native_options" "$analysis_options"
for ((pass = 1; pass <= iterations; pass++)); do
  run_analyze "Native analyzer, default persistent cache, pass $pass"
done

for ((pass = 1; pass <= iterations; pass++)); do
  run_analyze \
    "Native analyzer, isolated cache, pass $pass" \
    --cache="$fresh_cache"
done

cp "$original_options" "$analysis_options"
run_analyze "Plugin bootstrap/AOT preparation (excluded from comparison)"
for ((pass = 1; pass <= iterations; pass++)); do
  run_analyze "No-op semantic plugin, unchanged pass $pass"
done

echo
echo "Benchmark complete. Results saved to $output"
