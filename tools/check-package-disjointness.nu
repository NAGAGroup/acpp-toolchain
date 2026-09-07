# check-package-disjointness.nu — assert that no two acpp-* packages built for
# the same platform ship the same file.
#
# WHY THIS EXISTS. The old single recipe expressed each output as an include
# list plus an exclude list and had a partition audit to prove the two agreed.
# The rebuilt tree carves each package with its own list, and no two lists are
# checked against each other anywhere — forty-odd packages slicing one stage is
# forty-odd chances for two of them to claim the same path, which surfaces as a
# clobber in a user's environment rather than as a red build in ours. One
# package, acpp-clang-21, is additionally defined with an EXCLUDE list
# (the clang resource directory minus the five subtrees compiler-rt21 owns),
# and subtraction trades the risk of shipping too little for shipping too much.
# (The original subtraction package, acpp-llvm-dev, is gone: the lift replaced
# it with acpp-llvmdev, whose scope is a positive list from conda-forge's
# published artifact.)
#
# So this asserts the PROPERTY (the packages are disjoint) instead of the
# mechanism that is supposed to produce it (the glob lists agree). It reads
# built artifacts, which is the only thing that can be wrong in the way that
# matters.
#
# NOT VACUOUS BY CONSTRUCTION. A pairwise-disjointness assertion over zero or
# one artifact is trivially true, which is how a gate ends up green while
# checking nothing. `--expect` is REQUIRED and the run fails when a platform
# directory holds fewer artifacts than that, so the result is always "compared
# N packages and found no overlap" rather than "found no overlap".
#
# Usage (inside the dev environment, which supplies bsdtar via libarchive):
#   pixi run -e dev nu tools/check-package-disjointness.nu --artifacts ./out --expect 10

# A .conda is a zip holding two zstd tarballs. bsdtar reads both, so the file
# list comes out of a pipeline without unpacking anything to disk.
#
# The member is info/paths.json, NOT info/files: rattler-build writes
# paths.json and no files (checked against a real artifact — an info/files
# lookup errors with "Not found in archive").
def package-paths [artifact: string] {
  let raw = (^bsdtar -xOf $artifact "info-*.tar.zst" | ^bsdtar -xOf - "info/paths.json")
  $raw | from json | get paths | get _path
}

# The package NAME, read from the artifact's own metadata rather than parsed
# off the filename. It decides which pairs are comparable at all — see below.
def package-name [artifact: string] {
  let raw = (^bsdtar -xOf $artifact "info-*.tar.zst" | ^bsdtar -xOf - "info/index.json")
  $raw | from json | get name
}

def main [
  --artifacts: string    # directory of platform subdirectories holding .conda files
  --expect: int          # minimum artifacts REQUIRED in each platform subdirectory
] {
  if ($artifacts | is-empty) {
    error make {msg: "check-package-disjointness: --artifacts <dir> is required"}
  }
  if ($expect == null) or ($expect < 2) {
    # Below two there is no pair to compare, so any "pass" would be vacuous.
    error make {msg: "check-package-disjointness: --expect <n> is required and must be at least 2"}
  }

  let subdirs = (ls $artifacts | where type == dir | get name)
  if ($subdirs | is-empty) {
    error make {msg: $"check-package-disjointness: no platform subdirectories under ($artifacts)"}
  }

  mut failures = []
  for dir in $subdirs {
    let platform = ($dir | path basename)
    let pkgs = (glob $"($dir)/*.conda")
    # NB parentheses are escaped: inside an interpolated string `(...)` is a
    # subexpression, so a literal one runs as a command.
    print $"($platform): ($pkgs | length) artifacts, expecting at least ($expect)"
    if ($pkgs | length) < $expect {
      $failures = ($failures | append $"($platform): found ($pkgs | length) artifacts, expected at least ($expect) — the check would have compared too few packages to mean anything")
      continue
    }

    let entries = ($pkgs | each {|p| {
      file: ($p | path basename),
      name: (package-name $p),
      paths: (package-paths $p)
    }})

    # Every unordered pair, once — EXCEPT two builds of ONE package name.
    #
    # ⚠ SKIPPING SAME-NAME PAIRS IS REQUIRED, NOT A LOOSENING. `acpp-clang` and
    # `acpp-clangxx` are each built TWICE on every platform, once per `with_cfg`
    # row, and the two builds ship very nearly the same files by design — that
    # is what a variant IS. They can never be installed together (one name, one
    # version, the solver picks one build), so a shared path between them is not
    # a clobber. Comparing them would make this gate RED on a correct tree,
    # which is the failure mode that gets a gate deleted rather than fixed.
    #
    # The count printed below is therefore the number of pairs actually
    # COMPARED, not C(n,2): a reader who sees a smaller number should find the
    # variant pairs named in the line above it.
    let variant_pairs = ($entries | group-by name | items {|name, rows| {name: $name, builds: ($rows | length)} } | where builds > 1)
    if not ($variant_pairs | is-empty) {
      for v in $variant_pairs { print $"($platform): ($v.name) has ($v.builds) builds of one name \(a variant axis) — not compared against itself" }
    }

    mut compared = 0
    mut skipped = 0
    for i in 0..<(($entries | length) - 1) {
      for j in ($i + 1)..<($entries | length) {
        let a = ($entries | get $i)
        let b = ($entries | get $j)
        if $a.name == $b.name { $skipped = $skipped + 1; continue }
        $compared = $compared + 1
        let shared = ($a.paths | where {|p| $p in $b.paths })
        if not ($shared | is-empty) {
          $failures = ($failures | append $"($platform): ($a.file) and ($b.file) both ship ($shared | length) path\(s\), e.g. ($shared | first 5 | str join ', ')")
        }
      }
    }
    if $skipped > 0 { print $"($platform): ($skipped) same-name pair\(s\) skipped" }
    let total_files = ($entries | get paths | flatten | length)
    print $"($platform): compared ($compared) package pairs over ($total_files) shipped paths"
  }

  if not ($failures | is-empty) {
    for f in $failures { print $"FAIL ($f)" }
    error make {msg: $"check-package-disjointness: ($failures | length) failure\(s\) — see above"}
  }
  print "check-package-disjointness: OK"
}
