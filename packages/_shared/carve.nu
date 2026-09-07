# carve.nu — the ONE copy step every acpp-* subpackage runs.
#
# The stage package (_acpp-stage) installs the whole toolchain into
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
# ACPP_CARVE_EXCLUDE, same format, subtracts from that set. It exists for ONE
# package: acpp-llvm-dev is the development REMAINDER of an LLVM install
# (bin/**, include/**, lib/**/*.a, lib/cmake/**, share/man/**) minus everything
# its siblings claim. Enumerating that remainder positively would mean listing
# ~150 tool binaries and every header directory — an LLVM VERSION detail, not a
# contract of ours — and the failure mode would be invisible, since a glob that
# matches nothing is the only thing this script can detect and a header nobody
# listed matches nothing at all. Subtraction keeps the list short and the
# failure loud. Include-minus-exclude is still ONE list in ONE place driving
# both the copy and the ship, so the single-source-of-truth property holds.
#
# The trade it makes is under-shipping for OVER-shipping: a sibling's file
# leaking in here is an install-time clobber between two of our own packages.
# That is what tools/check-package-disjointness.nu asserts, on the built
# artifacts — the property itself, rather than the discipline meant to produce
# it.
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

# nushell's glob parser treats a backslash as an ESCAPE character, so a Windows
# path straight out of `path join` makes `glob` error out rather than match.
# Forward slashes are valid path separators on Windows, so normalizing is safe
# on every platform and is done to BOTH sides of every comparison below.
def slashes [] { str replace --all '\' '/' }

# Expand one list of final-package-path globs against the stage, returning the
# matched paths. A glob matching NOTHING is a defect on either side of the
# subtraction and errors here: an include that matches nothing means this
# package believes it ships something the build did not produce; an exclude
# that matches nothing means the list has rotted against a sibling that renamed
# or dropped a file, which is precisely when the remainder starts swallowing
# another package's files.
def expand-globs [stage: string, lib_prefix: string, globs: list<string>, kind: string] {
  mut out = []
  for g in $globs {
    # Globs are written as FINAL PACKAGE PATHS, so on Windows they start with
    # "Library/" — which is the layout root itself. Strip that prefix to find
    # the path inside the stage. One list serves both ends.
    let rel_to_root = (if ($lib_prefix != "" and ($g | str starts-with $lib_prefix)) {
      $g | str substring ($lib_prefix | str length)..
    } else {
      $g
    })
    let matches = (glob $"($stage)/($rel_to_root)")
    if ($matches | is-empty) {
      error make {msg: $"carve: ($kind) glob '($g)' matched nothing under ($stage)"}
    }
    $out = ($out | append ($matches | each { slashes }))
  }
  $out | uniq
}

def main [] {
  # Conda's Windows layout puts headers/libs/binaries under %PREFIX%\Library.
  # On unix the layout root IS the prefix.
  let layout_root = (if (is-windows) {
    $env.LIBRARY_PREFIX? | default ($env.PREFIX | path join "Library")
  } else {
    $env.PREFIX
  })
  let stage = ($layout_root | path join "_stage" | slashes)

  if not ($stage | path exists) {
    error make {msg: $"carve: stage directory ($stage) does not exist — is _acpp-stage a host dependency of this package?"}
  }

  let lib_prefix = (if (is-windows) { "Library/" } else { "" })

  let includes = ($env.ACPP_CARVE? | default "" | split row ";" | each {|g| $g | str trim } | where {|g| $g != "" })
  if ($includes | is-empty) {
    error make {msg: "carve: ACPP_CARVE is empty — the recipe must name the globs this package ships"}
  }
  # Optional and usually absent; see the header note on acpp-llvm-dev.
  let excludes = ($env.ACPP_CARVE_EXCLUDE? | default "" | split row ";" | each {|g| $g | str trim } | where {|g| $g != "" })

  let included = (expand-globs $stage $lib_prefix $includes "include")
  let excluded = (if ($excludes | is-empty) { [] } else {
    expand-globs $stage $lib_prefix $excludes "exclude"
  })
  let selected = ($included | where {|p| $p not-in $excluded })

  # Subtracting everything is the same class of defect as a glob matching
  # nothing: the package would ship empty and no later step would notice.
  if ($selected | is-empty) {
    error make {msg: "carve: every included path was excluded — this package would ship nothing"}
  }

  mut total = 0
  for m in $selected {
    # DIRECTORIES ARE NOT COPIED, only the files inside them (their parents are
    # created on demand below). A directory is not a shipped file, and with
    # exclusions a `**` include would otherwise leave behind the empty
    # directory skeleton of a subtree that belongs to a sibling package.
    if (($m | path type) == "dir") { continue }
    # The path INSIDE the stage, replayed at the top of the layout root —
    # identical relative depth, which is what keeps $ORIGIN/../lib valid.
    let rel = ($m | path relative-to $stage)
    let dst = ($layout_root | slashes | path join $rel)
    mkdir ($dst | path dirname)
    # -P, NOT -p. In nushell `-p` is `--progress` (a progress bar), and `cp`
    # DEREFERENCES symlinks unless told not to — measured: copying a 6-byte
    # symlink without -P produced a 2.1 kB regular file. An LLVM install tree
    # is a symlink farm (clang++/clang-cl/clang-cpp -> clang, ld.lld and the
    # other lld drivers -> lld, llvm-ranlib/llvm-lib/llvm-dlltool -> llvm-ar,
    # llvm-strip/llvm-install-name-tool -> llvm-objcopy, llvm-readelf ->
    # llvm-readobj, llvm-addr2line -> llvm-symbolizer), so dereferencing turns
    # each of those into a full copy of a ~150 MB binary. File MODE is
    # preserved by cp's default (`--preserve` defaults to mode), which is what
    # keeps the executable bit.
    cp -P $m $dst
    $total = $total + 1
  }
  let excl_note = (if ($excluded | is-empty) { "" } else { $", excluded ($excluded | length) paths" })
  print $"carve: copied ($total) files($excl_note) for ($env.PKG_NAME? | default "this package")"
}
