#!/usr/bin/env nu
# Install the runtime's backend-bitcode activation scripts into the package.
#
# This runs as the acpp-runtime OUTPUT's build script, deliberately NOT as
# part of the staging build: the staging cache is keyed on
# SHA(resolved requirements + variant vars) and does NOT hash the contents of
# shared/, so anything the staging script copies from there goes stale
# silently whenever we edit it (cost us a full debug cycle on 2026-08-08 —
# the win libdevice path fix never reached the package). Output scripts run
# on every build, so these files are always current.
#
# Sources come from shared-fresh/, a copy fetched by THIS output — not from
# the staging work dir, whose shared/ is restored from the cache and can be
# arbitrarily old. Missing files are a hard error, never a silent skip.

def is-windows [] { $nu.os-info.name == "windows" }

def main [] {
  let src = ($env.SRC_DIR | path join "shared-fresh" "activation")
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
