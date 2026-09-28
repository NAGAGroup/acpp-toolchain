#!/usr/bin/env nu
# Build the toolchain and assemble an INDEXED local conda channel from it.
#
# Why not `pixi publish`? pixi-build-rattler-build resolves a staging output's
# build environment with NO channels (reproduced 2026-09-27 on pixi 0.81.0 /
# backend 0.4.6: "No candidates were found for gcc_linux-64"). Driving
# rattler-build directly lets us pass `-c` explicitly.
#
#   nu shared/build-lane.nu

# Overlay channel: layers conda-forge server-side, and is where we publish.
const CHANNEL = "https://prefix.dev/jackm97/naga-labs-staging"
# Package subdirs to lift into the channel — deliberately NOT bld/ or
# src_cache/, which rattler-build also writes under --output-dir.
const SUBDIRS = [linux-64 noarch win-64 linux-aarch64 osx-arm64 win-arm64]

# Turn a filesystem path into a file:// URL that is valid on both platforms.
# Linux gives "/home/x" -> "file:///home/x"; Windows gives "C:/x" ->
# "file:///C:/x". Emitting "file://C:/x" instead would make "C:" the URL host.
def file-url [p: path] {
  let abs = ($p | path expand | str replace --all '\' '/')
  $"file:///($abs | str trim --left --char '/')"
}

def main [] {
  let recipe = "recipe.yaml"
  if not ($recipe | path exists) { error make {msg: $"no recipe at ($recipe)"} }

  # Variant config is per-platform, passed explicitly so the wrong platform's
  # file can never be picked up. Runners build natively, so the host names
  # the platform.
  let arm = ($nu.os-info.arch == "aarch64")
  let plat = (if $nu.os-info.name == "windows" {
    (if $arm { "win-arm64" } else { "win-64" })
  } else if $nu.os-info.name == "macos" {
    (if $arm { "osx-arm64" } else { "osx-64" })
  } else {
    (if $arm { "linux-aarch64" } else { "linux-64" })
  })
  let variants = ([shared variants $"($plat).yaml"] | path join)

  # CI points this at fast storage; local builds default to ./output.
  let outdir = ($env.ACPP_OUTPUT_DIR? | default "output")

  # ── 1. The mutex, FIRST ───────────────────────────────────────────────────
  # The staging host takes `naga-acpp-llvm ==<major>`, so the mutex must be
  # resolvable before the toolchain builds. Built here so everything
  # bootstraps from a clean clone. It goes to its own indexed directory, NOT
  # the output dir, so a stale past artifact can never satisfy a fresh solve.
  let mutexdir = ($outdir | path join "mutex-channel")
  if ($mutexdir | path exists) { rm -rf $mutexdir }
  (^rattler-build build
    --recipe ("mutex" | path join "recipe.yaml")
    --channel $CHANNEL
    --variant-config ("mutex" | path join "variants.yaml")
    --output-dir $mutexdir)
  ^rattler-index fs $mutexdir

  # ── 2. The toolchain, resolving the mutex it just built ───────────────────
  (^rattler-build build
    --recipe $recipe
    --experimental          # staging outputs
    --no-build-id           # stable work dir => ccache hits across runs
    --channel (file-url $mutexdir)
    --channel $CHANNEL
    --variant-config $variants
    --output-dir $outdir)

  if ("local-channel" | path exists) { rm -rf local-channel }
  mkdir local-channel
  for sub in $SUBDIRS {
    let src = ($outdir | path join $sub)
    if ($src | path exists) { cp -r $src ("local-channel" | path join $sub) }
  }
  if ((glob "local-channel/**/*.conda" | length) == 0) {
    error make {msg: $"local-channel is EMPTY after the copy — nothing under ($outdir) matched ($SUBDIRS | str join ', ')"}
  }

  # The mutex ships WITH the toolchain: consumers need it in the same channel.
  let mutex_noarch = ($mutexdir | path join "noarch")
  if ($mutex_noarch | path exists) {
    mkdir ("local-channel" | path join "noarch")
    # `glob`, not `ls`; and backslashes are glob ESCAPES in nushell, so
    # normalize win paths first.
    for f in (glob ($mutex_noarch | path join "*.conda" | str replace --all '\' '/')) {
      cp $f ("local-channel" | path join "noarch")
    }
  }

  ^rattler-index fs ./local-channel
  print $"indexed local channel: (ls local-channel | get name | str join ', ')"
}
