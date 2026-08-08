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
const SUBDIRS = [linux-64 noarch win-64]

def main [lane: string] {
  let recipe = ($lane | path join "recipe.yaml")
  if not ($recipe | path exists) { error make {msg: $"no recipe at ($recipe)"} }

  # Variant config is per-platform (linux uses gcc + sysroot; windows uses
  # clang-cl + vs). Passed explicitly rather than auto-discovered so the wrong
  # platform's file can never be picked up.
  let plat = (if $nu.os-info.name == "windows" { "win-64" } else { "linux-64" })
  let variants = ([shared variants $"($plat).yaml"] | path join)

  # CI points this at fast storage (the win runner's D: temp drive is ~6x
  # faster than C: for the small-file I/O that dominates work-dir/prefix
  # copies). Local builds default to ./output as before.
  let outdir = ($env.ACPP_OUTPUT_DIR? | default "output")

  (^rattler-build build
    --recipe $recipe
    --experimental          # staging outputs
    --no-build-id           # stable work dir => ccache hits across runs
    --channel $CHANNEL
    --variant-config $variants
    --output-dir $outdir)

  if ("local-channel" | path exists) { rm -rf local-channel }
  mkdir local-channel
  for sub in $SUBDIRS {
    let src = ($outdir | path join $sub)
    if ($src | path exists) { cp -r $src ("local-channel" | path join $sub) }
  }

  ^rattler-index fs ./local-channel
  print $"indexed local channel: (ls local-channel | get name | str join ', ')"
}
