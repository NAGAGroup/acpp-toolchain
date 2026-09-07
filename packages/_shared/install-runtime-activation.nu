#!/usr/bin/env nu
# Install the CUDA backend-bitcode activation scripts into the package.
#
# Runs as acpp-runtime-cuda's build script: the base runtime ships no
# activation, and this is the package whose install guarantees libdevice
# exists. Its recipe asserts these files in package_contents, so this script is
# load-bearing and not scaffolding.
#
# ⚠ THE SOURCE DIRECTORY IS `activation/`, WHICH IS WHAT THE RECIPE PROVIDES.
# This script was written for round 1's rattler `staging:` design, where the
# shared tree arrived as `shared/` (or `shared-fresh/` on staging-inheriting
# outputs) — both of which died with that design. The recipe has said
# `- path: ../_shared/activation / target_directory: activation` since the
# group-7 redesign, so the script was reading a directory nothing provides and
# failing with "activation source missing" (run 34119652637).
#
# The recipe's `target_directory` and the path read here are ONE fact written
# in two files; tools/check-source-paths.nu now asserts they agree, which is
# the only reason this cannot drift apart again silently.
#
# Missing files stay a hard error, never a silent skip.

def is-windows [] { $nu.os-info.name == "windows" }

def main [] {
  let src = ($env.SRC_DIR | path join "activation")
  if not ($src | path exists) {
    error make {msg: $"activation directory missing at ($src) — the recipe must provide `- path: ../_shared/activation` with `target_directory: activation`"}
  }
  # Activation scripts always live under $PREFIX/etc, never %PREFIX%\Library\etc.
  let act = ($env.PREFIX | path join "etc" "conda" "activate.d")
  mkdir $act

  let files = (if (is-windows) {
    # Per-shell triple; the win .sh differs from linux's (Library paths, copy
    # instead of symlink), so it is renamed into place.
    [["acpp-runtime-activate.bat", "acpp-runtime-activate.bat"]
     ["acpp-runtime-activate.ps1", "acpp-runtime-activate.ps1"]
     ["acpp-runtime-activate-win.sh", "acpp-runtime-activate.sh"]]
  } else {
    [["acpp-runtime-activate.sh", "acpp-runtime-activate.sh"]]
  })

  for f in $files {
    let from = ($src | path join $f.0)
    if not ($from | path exists) {
      error make {msg: $"activation source missing: ($from)"}
    }
    cp $from ($act | path join $f.1)
    print $"installed ($f.1)"
  }
}
