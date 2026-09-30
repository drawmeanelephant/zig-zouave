#!/usr/bin/env bash
set -euo pipefail

limit="${INPUT_CACHE_SIZE_LIMIT:-2048}"
[[ "$limit" =~ ^[0-9]+$ ]] || { echo "::error::cache-size-limit must be a nonnegative integer (MiB)" >&2; exit 1; }
(( limit > 0 )) || exit 0

cache_dir="$GITHUB_WORKSPACE/.zig-cache"
if [[ "${RUNNER_OS:-}" == Windows ]]; then
  cache_dir="$(cygpath -u "$GITHUB_WORKSPACE")/.zig-cache"
fi
[[ -d "$cache_dir" ]] || exit 0
size_kib="$(du -sk "$cache_dir" | cut -f1)"
if (( size_kib > limit * 1024 )); then
  echo "Zig cache is ${size_kib} KiB, over ${limit} MiB; clearing it"
  find "$cache_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
fi
