# install_lld.nu — acpp-lld's slice of the stage.
#
# LIFTED FROM lld-feedstock's `build.sh` / `bld.bat` (vendored in the reference
# monolith at recipe/lld/). lld is one of the feedstocks that does NOT slice:
# it is a single-package recipe with no `outputs:` and no `files:`, so its
# package is "whatever the build installed". The script IS the slice, and it
# stays a script — the same treatment acpp-llvm-openmp gets.
#
# THE STRUCTURAL CHANGE, and it is forced: upstream's build installs into its
# OWN prefix, which holds lld and nothing else. Our `_acpp-stage` is a UNION
# build (llvm + clang + clang-tools-extra + lld + lldb + openmp + compiler-rt +
# AdaptiveCpp) installed into <layout_root>/_stage, so "whatever the build
# installed" is not recoverable from the tree.
#
# SCOPE is therefore derived from conda-forge's PUBLISHED lld-21.1.8 artifact.
# Re-read the contract with:
#   pixi run -e dev nu tools/upstream-paths.nu lld 21.1.8 <platform>
# 31 paths, and the set is IDENTICAL on linux-64, osx-arm64 and win-64 — five
# drivers, the sixteen public headers, the four cmake files and the six static
# libraries, with only the platform's own naming applied. That uniformity is
# why there are no optional entries here: every path is required and a missing
# one fails the build.
#
# All five drivers except `lld` itself are symlinks to it on unix, hence cp -P.

def is-windows [] { $nu.os-info.name == "windows" }
def slashes [] { str replace --all '\' '/' }

def place [src: string, layout_root: string, stage: string] {
  let rel = ($src | path relative-to $stage)
  let dst = ($layout_root | slashes | path join $rel)
  mkdir ($dst | path dirname)
  cp -P $src $dst
}

# Copy a whole directory out of the stage, at identical relative depth. Returns
# the number of FILES placed; a directory that is absent or empty is a defect on
# the same footing as a missing named file.
def place-tree [rel: string, layout_root: string, stage: string] {
  let src = ($stage | path join $rel)
  if not ($src | path exists) {
    error make {msg: $"install_lld: ($rel) is a required part of this package and is not in the stage at ($src) — the slice has rotted against the stage"}
  }
  let files = (glob $"($src)/**/*" | where {|p| ($p | path type) != "dir" })
  if ($files | is-empty) {
    error make {msg: $"install_lld: ($rel) exists in the stage but contains no files"}
  }
  for f in $files { place $f $layout_root $stage }
  $files | length
}

def main [] {
  let layout_root = (if (is-windows) {
    $env.LIBRARY_PREFIX? | default ($env.PREFIX | path join "Library")
  } else {
    $env.PREFIX
  })
  let stage = ($layout_root | path join "_stage" | slashes)
  if not ($stage | path exists) {
    error make {msg: $"install_lld: stage directory ($stage) does not exist — is _acpp-stage a host dependency of this package?"}
  }

  # The five linker drivers, and the six static libraries. Windows drops the
  # `lib` prefix and takes `.lib`; that is the only difference in the whole set.
  let drivers = ["ld.lld" "ld64.lld" "lld" "lld-link" "wasm-ld"]
  let libs = ["COFF" "Common" "ELF" "MachO" "MinGW" "Wasm"]
  let required = (if (is-windows) {
    ($drivers | each {|d| $"bin/($d).exe" })
      | append ($libs | each {|l| $"lib/lld($l).lib" })
  } else {
    ($drivers | each {|d| $"bin/($d)" })
      | append ($libs | each {|l| $"lib/liblld($l).a" })
  })

  mut placed = 0
  for rel in $required {
    let src = ($stage | path join $rel)
    if not ($src | path exists) {
      error make {msg: $"install_lld: ($rel) is a required part of this package and is not in the stage at ($src) — the slice has rotted against the stage"}
    }
    place $src $layout_root $stage
    $placed = $placed + 1
  }

  # The public headers and the CMake package. Both live in lld-owned
  # directories, so a tree copy cannot reach another project's output even
  # though the stage is a union build.
  $placed = $placed + (place-tree "include/lld" $layout_root $stage)
  $placed = $placed + (place-tree "lib/cmake/lld" $layout_root $stage)

  print $"install_lld: placed ($placed) files"
}
