#!/usr/bin/env bash
# shellcheck disable=SC2153 # GitHub Actions supplies RUNNER_* and GITHUB_* variables.
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required to read Zig's download index"
command -v curl >/dev/null || die "curl is required to download Zig"

version="${INPUT_VERSION:-}"
if [[ -z "$version" && -f build.zig.zon ]]; then
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
      version="${BASH_REMATCH[1]}"
      break
    fi
  done < build.zig.zon
fi
version="${version:-latest}"

case "${RUNNER_OS:-}" in
  Linux) os=linux ;;
  macOS) os=macos ;;
  Windows) os=windows ;;
  *) die "Unsupported runner OS: ${RUNNER_OS:-unset}" ;;
esac
case "${RUNNER_ARCH:-}" in
  X64) arch=x86_64 ;;
  ARM64) arch=aarch64 ;;
  *) die "Unsupported runner architecture: ${RUNNER_ARCH:-unset}" ;;
esac
[[ "$os" != windows || "$arch" == x86_64 ]] || die "Only x86_64 Windows is supported"
platform="$arch-$os"

if [[ "$os" == windows ]]; then
  runner_temp="$(cygpath -u "$RUNNER_TEMP")"
  workspace="$(cygpath -u "$GITHUB_WORKSPACE")"
  github_path="$(cygpath -u "$GITHUB_PATH")"
  github_output="$(cygpath -u "$GITHUB_OUTPUT")"
  github_env="$(cygpath -u "$GITHUB_ENV")"
else
  runner_temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  workspace="$GITHUB_WORKSPACE"
  github_path="$GITHUB_PATH"
  github_output="$GITHUB_OUTPUT"
  github_env="$GITHUB_ENV"
fi
work="$(mktemp -d "$runner_temp/zig-zouave.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
curl --fail --location --silent --show-error --retry 3 \
  https://ziglang.org/download/index.json -o "$work/index.json"

if [[ "$version" == latest ]]; then
  version="$(jq -er '[keys[] | select(test("^[0-9]+[.][0-9]+[.][0-9]+$"))] |
    sort_by(split(".") | map(tonumber)) | last' "$work/index.json")"
  entry="$version"
elif [[ "$version" == master ]]; then
  entry=master
  version="$(jq -er '.master.version' "$work/index.json")"
else
  entry="$version"
  if ! jq -e --arg v "$entry" 'has($v)' "$work/index.json" >/dev/null; then
    if [[ "$(jq -r '.master.version' "$work/index.json")" == "$version" ]]; then
      entry=master
    else
      die "Version '$version' is not in the Zig download index (old nightly builds have no indexed checksum)"
    fi
  fi
fi
[[ "$version" =~ ^[a-zA-Z0-9.+_-]+$ ]] || die "Invalid Zig version: $version"

url="$(jq -er --arg v "$entry" --arg p "$platform" '.[$v][$p].tarball' "$work/index.json")" ||
  die "No Zig archive for $version on $platform"
expected="$(jq -er --arg v "$entry" --arg p "$platform" '.[$v][$p].shasum' "$work/index.json")" ||
  die "No SHA-256 digest for $version on $platform"
[[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || die "Invalid SHA-256 digest in Zig index"
[[ "$url" == https://ziglang.org/* ]] || die "Unexpected Zig archive URL in index: $url"

case "${INPUT_USE_TOOL_CACHE:-}" in
  true) use_tool_cache=true ;;
  false) use_tool_cache=false ;;
  '') if [[ "${RUNNER_ENVIRONMENT:-}" == github-hosted ]]; then
        use_tool_cache=false
      else
        use_tool_cache=true
      fi ;;
  *) die "use-tool-cache must be true, false, or empty" ;;
esac
if [[ "$use_tool_cache" == true ]]; then
  [[ -n "${RUNNER_TOOL_CACHE:-}" ]] || die "RUNNER_TOOL_CACHE is required when use-tool-cache is true"
  if [[ "$os" == windows ]]; then
    tool_dir="$(cygpath -u "$RUNNER_TOOL_CACHE")/zig-zouave/$version/$platform"
  else
    tool_dir="$RUNNER_TOOL_CACHE/zig-zouave/$version/$platform"
  fi
else
  tool_dir="$runner_temp/zig-zouave/$version/$platform"
fi
binary=zig
[[ "$os" == windows ]] && binary=zig.exe

if [[ ! -f "$tool_dir/$binary" ]]; then
  filename="${url##*/}"
  download_url="$url"
  if [[ -n "${INPUT_MIRROR:-}" ]]; then
    download_url="${INPUT_MIRROR%/}/$filename"
  fi
  archive="$work/$filename"
  echo "Downloading Zig $version for $platform from $download_url"
  curl --fail --location --silent --show-error --retry 3 "$download_url" -o "$archive"
  if command -v sha256sum >/dev/null; then
    actual="$(sha256sum "$archive" | cut -d' ' -f1)"
  else
    actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
  fi
  [[ "${actual,,}" == "${expected,,}" ]] || die "SHA-256 mismatch for $filename"
  echo "SHA-256 verified against ziglang.org/download/index.json"

  mkdir -p "$work/extracted" "$(dirname "$tool_dir")"
  if [[ "$os" == windows ]]; then
    export ARCHIVE_PATH DEST_PATH
    ARCHIVE_PATH="$(cygpath -w "$archive")"
    DEST_PATH="$(cygpath -w "$work/extracted")"
    # PowerShell expands these environment variables, not bash.
    # shellcheck disable=SC2016
    powershell.exe -NoProfile -NonInteractive -Command \
      'Expand-Archive -LiteralPath $env:ARCHIVE_PATH -DestinationPath $env:DEST_PATH'
    root="$work/extracted/${filename%.zip}"
  else
    tar -xJf "$archive" -C "$work/extracted"
    root="$work/extracted/${filename%.tar.xz}"
  fi
  [[ -f "$root/$binary" ]] || die "Zig executable missing from extracted archive"
  mv "$root" "$tool_dir"
fi

installed="$("$tool_dir/$binary" version)"
[[ "$installed" == "$version" ]] || die "Installed Zig version $installed does not match $version"
echo "Installed Zig $installed in $tool_dir"
if [[ "$os" == windows ]]; then
  cygpath -w "$tool_dir" >> "$github_path"
else
  echo "$tool_dir" >> "$github_path"
fi
echo "version=$version" >> "$github_output"

# Match setup-zig: put both the global and local cache in one cached directory.
cache_dir="$workspace/.zig-cache"
mkdir -p "$cache_dir"
if [[ "$os" == windows ]]; then cache_dir="$(cygpath -w "$cache_dir")"; fi
{
  echo "ZIG_GLOBAL_CACHE_DIR=$cache_dir"
  echo "ZIG_LOCAL_CACHE_DIR=$cache_dir"
} >> "$github_env"
