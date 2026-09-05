#!/usr/bin/env nu
# Install the CUDA backend-bitcode activation scripts into the package.
#
# Runs as the acpp-runtime-CUDA output's build script: base packages ship no
# activation, and this is the package whose install guarantees libdevice
# exists. Deliberately NOT part of the staging build — the staging cache is
# keyed on SHA(resolved requirements + variant vars) and does NOT hash
# shared/, so staging-copied scripts go stale silently. Output scripts run
# on every build, so these files are always current.
#
# Sources come from this output's own fetched copy of shared/ (target dir
# shared-fresh on staging-inheriting outputs, shared on plain ones).
# Missing files are a hard error, never a silent skip.

def is-windows [] { $nu.os-info.name == "windows" }

def main [] {
  let fresh = ($env.SRC_DIR | path join "shared-fresh")
  let root = (if ($fresh | path exists) { $fresh } else { $env.SRC_DIR | path join "shared" })
  let src = ($root | path join "activation")
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
