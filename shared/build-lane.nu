#!/usr/bin/env nu
# Build one lane and assemble an INDEXED local conda channel from its outputs.
#
# Why not `pixi publish --to ./local-channel`? The pixi-build-rattler-build
# backend does not forward the workspace channels into the build environment
# that rattler-build resolves — the resolve sees only rattler-build's own
# output directory, so `gcc_linux-64 14.*` (and everything else) is unsolvable.
# Driving rattler-build directly lets us pass `-c` explicitly, which is also
# what makes dogfooding the naga-labs channel possible.
#
#   nu shared/build-lane.nu release
#   nu shared/build-lane.nu nightly

const CHANNEL = "https://prefix.dev/jackm97/naga-labs"
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

def main [lane: string] {
  let recipe = ($lane | path join "recipe.yaml")
  if not ($recipe | path exists) { error make {msg: $"no recipe at ($recipe)"} }

  # Variant config is per-platform (linux uses gcc + sysroot; windows uses
  # clang-cl + vs). Passed explicitly rather than auto-discovered so the wrong
  # platform's file can never be picked up. Arch-aware: the arm runners build
  # natively, so the host arch names the platform.
  let arm = ($nu.os-info.arch == "aarch64")
  let plat = (if $nu.os-info.name == "windows" {
    (if $arm { "win-arm64" } else { "win-64" })
  } else if $nu.os-info.name == "macos" {
    (if $arm { "osx-arm64" } else { "osx-64" })
  } else {
    (if $arm { "linux-aarch64" } else { "linux-64" })
  })
  let variants = ([shared variants $"($plat).yaml"] | path join)

  # CI points this at fast storage (the win runner's D: temp drive is ~6x
  # faster than C: for the small-file I/O that dominates work-dir/prefix
  # copies). Local builds default to ./output as before.
  let outdir = ($env.ACPP_OUTPUT_DIR? | default "output")

  # ── 1. The mutex, FIRST ───────────────────────────────────────────────────
  # The lane outputs take `acpp-llvm ==<major>` as a host dependency, so the
  # mutex has to be resolvable before the lane can be built. Building it here
  # rather than requiring it to be published first means the whole thing
  # bootstraps from a clean clone on a clean runner, and a brand-new major
  # never needs a manual "publish the mutex, then build" round trip.
  #
  # It goes to its own indexed directory, NOT the lane output dir: the lane dir
  # accumulates previous artifacts, and pointing a build's channel list at its
  # own past outputs is how a stale package silently satisfies a fresh solve.
  let mutexdir = ($outdir | path join "mutex-channel")
  if ($mutexdir | path exists) { rm -rf $mutexdir }
  (^rattler-build build
    --recipe ("mutex" | path join "recipe.yaml")
    --channel $CHANNEL
    --variant-config ("mutex" | path join "variants.yaml")
    --output-dir $mutexdir)
  ^rattler-index fs $mutexdir

  # ── 2. The lane, resolving the mutex it just built ────────────────────────
  # Mutex channel first: it holds exactly one package name, so under strict
  # channel priority everything else still falls through to naga-labs.
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
  # An empty channel here means the platform subdir list above fell behind
  # the platform set — fail HERE, not at the publish gate three jobs later
  # (an empty staged set passes every per-artifact gate vacuously; that is
  # exactly how run 33955587720 reached the uploader with nothing).
  if ((glob "local-channel/**/*.conda" | length) == 0) {
    error make {msg: $"local-channel is EMPTY after the copy — nothing under ($outdir) matched ($SUBDIRS | str join ', ')"}
  }

  # The mutex ships WITH the lane: a consumer resolving acpp-runtime needs
  # acpp-llvm to exist in the same channel or the solve is unsatisfiable.
  # Uploads use --skip-existing for this name, so republishing an unchanged
  # mutex from every lane run is a no-op rather than a 409.
  let mutex_noarch = ($mutexdir | path join "noarch")
  if ($mutex_noarch | path exists) {
    mkdir ("local-channel" | path join "noarch")
    # `glob`, not `ls`: nushell expands glob patterns only for bare words, so
    # `ls $pattern` would look for a file literally named "*.conda".
    # Backslashes are glob ESCAPES in nushell — normalize win paths before
    # globbing or the parse fails (this killed run 31352823522 at packaging).
    for f in (glob ($mutex_noarch | path join "*.conda" | str replace --all '\' '/')) {
      cp $f ("local-channel" | path join "noarch")
    }
  }

  ^rattler-index fs ./local-channel
  print $"indexed local channel: (ls local-channel | get name | str join ', ')"
}
