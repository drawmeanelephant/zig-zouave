# zig-zouave

A small composite GitHub Action that installs Zig without bundling Node.js or
`node_modules`. Swap `drawmeanelephant/setup-zig` for
`drawmeanelephant/zig-zouave` while keeping the same input names.

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: drawmeanelephant/zig-zouave@main
    with:
      version: '0.15.2'
  - run: zig build test
```

Pin the action to a commit SHA for reproducible builds. If `version` is omitted,
the action reads `minimum_zig_version` from `build.zig.zon` in the working
directory. If there is no such field, it installs the latest tagged release.

| Input | Default | Meaning |
| --- | --- | --- |
| `version` | `''` | Exact version in the official index, `master` for the current nightly, `latest` for the highest tagged release, or empty for `build.zig.zon` with a `latest` fallback. |
| `mirror` | `''` | Override the archive download base URL. The official index still supplies the expected SHA-256. |
| `use-cache` | `true` | Restore and save the combined global/local Zig compilation cache with `actions/cache@v4`. |
| `cache-key` | `''` | Extra cache key component for different jobs or matrix configurations. |
| `cache-size-limit` | `2048` | Size limit in MiB; an oversized restored cache is cleared. `0` disables the limit. |
| `use-tool-cache` | `''` | `true` uses `$RUNNER_TOOL_CACHE`; `false` uses `$RUNNER_TEMP`. Empty defaults to `false` on GitHub-hosted runners, `true` otherwise. |

Supports Linux and macOS on x86_64 and aarch64, and Windows on x86_64.
Requires `bash`, `curl`, `jq`, and a SHA-256 utility (`sha256sum` or
`shasum`). The archive is extracted with `tar` (or Windows PowerShell).

## Verification

**This action ships SHA-256 verification, not minisign verification.** It
fetches `https://ziglang.org/download/index.json` over HTTPS, reads the
platform's `shasum`, hashes the downloaded archive, and **fails** if they
disagree. This also applies when downloading from a custom mirror. A pinned,
preverified static minisign executable for every supported OS/architecture
would itself need distribution, maintenance, and verification, so this
minimal shell action does not download one at runtime.

The trade-off is that integrity depends on TLS and the Zig download index:
compromise of the index (or its HTTPS delivery) could change both the archive
URL and expected digest. Unlike the upstream minisign check, this does not
authenticate an archive against Zig's published signing key. Old nightlies
which are absent from the index cannot be verified and therefore fail.

## Differences from setup-zig

- This action downloads directly from the official index URL, rather than
  probing the community mirror list. Set `mirror` to choose a mirror yourself.
- It does not resolve Mach-nominated version aliases. Only versions present
  in Zig's official index are accepted, so every download has an indexed hash.
- It does not cache the Zig archive across workflows. Persistent tool cache
  reuse is available on self-hosted runners via `use-tool-cache`.
- GitHub Actions composite actions have no post-job shell hook. The cache
  size limit is enforced immediately **after restore**, not after the build;
  a cache that grows past the limit during the job can be saved once and will
  be cleared on the next restore. Compilation caches are keyed by runner OS,
  architecture, job, version, and `cache-key`.
- The action itself contains no JavaScript, but `actions/cache@v4` is a
  separately maintained GitHub Action that uses the runner's Node runtime.
  Set `use-cache: false` to avoid that dependency entirely.

The Zig global and local cache environment variables both point to the
workspace's `.zig-cache`, like the original action. Add `.zig-cache/` to your
project's `.gitignore` if necessary.

MIT licensed. See [LICENSE](LICENSE).
