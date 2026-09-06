# carve.nu — the ONE copy step every acpp-* subpackage runs.
#
# The stage package (acpp-stage) installs the whole toolchain into
# <layout_root>/_stage. It arrives here as a HOST dependency, so all of it is
# already sitting in $PREFIX and none of it is NEW — a conda package is the
# file DIFF of its build, so nothing would be captured. This script copies THIS
# package's portion up to the top level, and those copies are the diff.
#
# The portion is given by the recipe in the ACPP_CARVE environment variable: a
# semicolon-separated list of globs written EXACTLY as the final package paths,
# i.e. relative to $PREFIX and carrying the `Library/` prefix on Windows
# (`bin/acpp`, `lib/hipSYCL/**`, `Library/bin/opt.exe`). Written ONCE per
# package, so the "what to copy" list and the "what to ship" list are the same
# list and cannot drift apart.
#
# There is deliberately NO `files:` block in the subpackage recipes. A conda
# package is the file diff of its build, and the only new files this script
# creates are exactly these copies — so capture-everything-new IS the carve.
# A second list would be a second source of truth, and the two failure modes
# it introduces are both silent: copied-but-not-captured ships a package with
# a hole, captured-but-not-copied ships nothing at all.
#
# LAYOUT MIRROR — LOAD-BEARING. Files land at the SAME relative path they hold
# inside _stage. Binaries carry $ORIGIN-relative rpaths ($ORIGIN/../lib) which
# survive the move only because _stage/bin -> _stage/lib is the same relative
# relationship as bin -> lib. The clang driver finds its resource directory the
# same way. Copying to a different depth would break both, silently, at
# consumer runtime rather than at build time.

def is-windows [] { $nu.os-info.name == "windows" }

def main [] {
  # Conda's Windows layout puts headers/libs/binaries under %PREFIX%\Library.
  # On unix the layout root IS the prefix.
  let layout_root = (if (is-windows) {
    $env.LIBRARY_PREFIX? | default ($env.PREFIX | path join "Library")
  } else {
    $env.PREFIX
  })
  let stage = ($layout_root | path join "_stage")

  if not ($stage | path exists) {
    error make {msg: $"carve: stage directory ($stage) does not exist — is acpp-stage a host dependency of this package?"}
  }

  let globs = ($env.ACPP_CARVE? | default "" | split row ";" | each {|g| $g | str trim } | where {|g| $g != "" })
  if ($globs | is-empty) {
    error make {msg: "carve: ACPP_CARVE is empty — the recipe must name the globs this package ships"}
  }

  # Globs are written as FINAL PACKAGE PATHS, so on Windows they start with
  # "Library/" — which is the layout root itself. Strip that prefix to find the
  # path inside the stage, then replay the whole glob verbatim under $PREFIX.
  # One list serves both ends; nothing is written twice.
  let lib_prefix = (if (is-windows) { "Library/" } else { "" })

  mut total = 0
  for g in $globs {
    let rel_to_root = (if ($lib_prefix != "" and ($g | str starts-with $lib_prefix)) {
      $g | str substring ($lib_prefix | str length)..
    } else {
      $g
    })
    let matches = (glob ($stage | path join $rel_to_root))
    if ($matches | is-empty) {
      # A glob matching nothing is a DEFECT, not a no-op: it means this
      # package believes it ships something the build did not produce. Failing
      # here costs seconds; shipping a hollow package costs a release.
      error make {msg: $"carve: glob '($g)' matched nothing under ($stage)"}
    }
    for m in $matches {
      # The path INSIDE the stage, replayed at the top of the layout root —
      # identical relative depth, which is what keeps $ORIGIN/../lib valid.
      let rel = ($m | path relative-to $stage)
      let dst = ($layout_root | path join $rel)
      if (($m | path type) == "dir") {
        mkdir $dst
      } else {
        mkdir ($dst | path dirname)
        cp -p $m $dst
        $total = $total + 1
      }
    }
  }
  print $"carve: copied ($total) files for ($env.PKG_NAME? | default "this package")"
}
