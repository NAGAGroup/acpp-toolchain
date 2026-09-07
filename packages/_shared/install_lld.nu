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

# ⚠ EVERY GLOB GOES THROUGH THIS. On Windows `path join` emits BACKSLASHES,
# and a backslash is an ESCAPE character in a nushell glob pattern — so a
# pattern built from `path join` does not merely fail to match, it fails to
# PARSE (`failed to parse glob expression`, win run 34129107780). Forward
# slashes are valid separators on Windows, so normalising is safe everywhere
# and is done on every platform rather than under an `if windows`, which would
# leave the win path untested on linux.
#
# It also ASSERTS the result is clean: a backslash surviving normalisation
# means the pattern carried an intentional escape, which nothing here wants,
# and that assertion fires on ANY platform — including a linux laptop, where
# `path join` would never have produced one.
# ⚠ ONE CANONICALISER FOR BOTH SIDES OF EVERY PATH COMPARISON.
# `path expand` makes a path absolute — on Windows that ADDS THE DRIVE LETTER,
# because nushell resolves `/tmp/x` against the current drive as `C:\tmp\x` —
# and canonicalize may return the verbatim `\\?\` prefix. Glob RESULTS come back
# expanded; a root built by hand does not. Win run 34135577725 failed on exactly
# that difference AFTER separators were already normalised: results
# `C:/tmp/stage-fixups-windows/...` against a root `/tmp/stage-fixups-windows`,
# and `path relative-to` cannot find a prefix that is missing a drive.
#
# nushell#15707's reporter stripped the drive letter to work around this;
# canonicalising BOTH sides keeps it, which is the answer that stays correct
# when the path is used for anything other than matching.
def canon-path [p: string] {
  $p | path expand | str replace '\\?\' '' | str replace --all '\' '/'
}

def glob-native [pattern: string, --no-dir] {
  # Strip Windows' VERBATIM prefix FIRST. `path expand` calls Rust's canonicalize,
  # which on Windows returns extended-length paths like `\\?\C:\bld\...`, and no
  # glob parser handles those. nushell#15707 reports exactly this shape: a
  # pattern built from `path expand`/`path join` fails to parse while the same
  # path written as a literal works — which is why "backslash is an escape" is
  # only half the story. Our own prefix and build dir go through `path expand`,
  # so this is the form we would meet.
  let p = ($pattern | str replace '\\?\' '' | str replace --all '\' '/')
  if ($p | str contains '\') {
    error make {msg: $"glob-native: pattern still contains a backslash after normalisation: ($p)"}
  }
  # ⚠ AND THE RESULTS ARE NORMALISED TOO, which is the other half. On Windows
  # glob RETURNS backslash paths (or verbatim ones), so a caller comparing a
  # result against a forward-slash root — `path relative-to`, `str starts-with`,
  # `=~` — fails with `prefix not found` even though the pattern was fine. Win
  # run 34134434830 died in exactly that way, in the harness's own snapshot,
  # AFTER the fixups themselves had passed. Both sides of every comparison must
  # be forward-slash, and returning them normalised is the one place that makes
  # every caller correct at once.
  let hits = (if $no_dir { glob $p --no-dir } else { glob $p })
  $hits | each {|h| $h | str replace '\\?\' '' | str replace --all '\' '/' }
}

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
  let files = (glob-native $"($src)/**/*" | where {|p| ($p | path type) != "dir" })
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