# Exercise the stage's post-install fixups for IDEMPOTENCE.
#
# WHY THIS EXISTS. "Restored from cache" does not mean the stage is skipped: the
# script RE-RUNS against the cached build directory and the already-installed
# prefix. ninja is a no-op, `cmake --install` reports Up-to-date, the package is
# re-written — and every post-install fixup executes a SECOND time against a
# prefix that is already fixed up. Run 34115417814 died there with zero
# archives, when the openmp header move met the symlink that clang's fixup had
# left in its place.
#
# So the property is: EVERY fixup is a no-op on a second pass. Not "the ones we
# remembered" — this harness runs them all twice against a synthetic stage tree
# and asserts that pass two changes nothing and errors nothing, which is the
# only form of the check that keeps working as fixups are added.
#
# The audit that came with it found two more, neither of which had shown up yet:
#   * the clang re-versioning loop DESTROYED content on a second pass — it
#     deleted the real versioned binary, moved the symlink onto its name and
#     relinked, leaving a symlink pointing at itself;
#   * the flang config file grew by one line per pass, because it was composed
#     by appending to whatever was already on disk.
#
#   pixi run -e packaging nu tools/tests/exercise-stage-fixups.nu

const STAGE = "packages/_acpp-stage/build-stage.nu"

# A synthetic stage tree with the shapes the fixups act on: versioned and
# unversioned clang drivers, the openmp headers in the resource directory where
# an in-tree build puts them, clang's own headers beside them, the compiler-rt
# runtimes, libgomp and libarcher.
def make-tree [root: string] {
  rm -rf $root
  mkdir $"($root)/bin" $"($root)/lib" $"($root)/lib/clang/21/include" $"($root)/lib/clang/21/lib/linux"
  for n in ["clang-21" "clang-tidy" "clang-format" "clang-scan-deps-21" "clang-offload-packager-21" "clangd"] {
    $"#!/bin/sh\n# ($n)\n" | save -f $"($root)/bin/($n)"
  }
  for n in ["omp.h" "ompx.h" "omp-tools.h" "ompt.h" "ompt-multiplex.h"] {
    $"// openmp ($n)\n" | save -f $"($root)/lib/clang/21/include/($n)"
  }
  for n in ["stddef.h" "immintrin.h"] {
    $"// clang ($n)\n" | save -f $"($root)/lib/clang/21/include/($n)"
  }
  for n in ["asan" "tsan" "ubsan_standalone"] {
    $"// rt\n" | save -f $"($root)/lib/clang/21/lib/linux/libclang_rt.($n).so"
  }
  "// builtins\n" | save -f $"($root)/lib/clang/21/lib/linux/libclang_rt.builtins.a"
  "// gomp\n" | save -f $"($root)/lib/libgomp.so"
  "// archer\n" | save -f $"($root)/lib/libarcher.so"
}

# The tree's full state: every path, plus what each symlink points at. Two
# snapshots being equal is what "changed nothing" means.
def snapshot [root: string] {
  glob $"($root)/**/*" --no-dir
  | each {|p|
      let rel = ($p | path relative-to $root)
      let t = ($p | path type)
      if $t == "symlink" {
        $"($rel) -> (ls -l $p | get 0.target)"
      } else {
        $"($rel) [(open --raw $p | str length) bytes]"
      }
    }
  | sort
}

def run-fixups [root: string] {
  ^nu -c $"source ($STAGE); compiler-rt-install-fixups '($root)' '($root)'; openmp-header-fixups '($root)' '($root)'; clang-install-fixups-unix '($root)'; openmp-install-fixups '($root)'"
}

def main [] {
  cd ($env.FILE_PWD | path dirname | path dirname)
  let root = "/tmp/stage-fixups"
  mut results = []

  make-tree $root
  let p1 = (with-env {ACPP_LLVM_MAJOR: "21", ACPP_LLVM_MAJ_MIN: "21.1", CONDA_BUILD_SYSROOT: "", BUILD_PREFIX: ""} { run-fixups $root | complete })
  if $p1.exit_code != 0 {
    print "FAIL: the fixups do not survive their FIRST pass on a clean tree"
    print ($p1.stderr | lines | last 12 | str join "\n")
    error make {msg: "stage fixups failed on pass one"}
  }
  print "PASS: pass one succeeds on a clean tree"
  print ($p1.stdout | lines | each {|l| $"      ($l)" } | str join "\n")
  let after_one = (snapshot $root)

  # THE ASSERTION. A cached run re-executes everything against this tree.
  let p2 = (with-env {ACPP_LLVM_MAJOR: "21", ACPP_LLVM_MAJ_MIN: "21.1", CONDA_BUILD_SYSROOT: "", BUILD_PREFIX: ""} { run-fixups $root | complete })
  if $p2.exit_code != 0 {
    print "FAIL: pass TWO errored — a fixup is not idempotent, and a cache-restored run will die here"
    print ($p2.stderr | lines | last 12 | str join "\n")
    $results = ($results | append false)
  } else {
    print "PASS: pass two runs without error"
    $results = ($results | append true)
  }
  let after_two = (snapshot $root)

  let added = ($after_two | where {|x| $x not-in $after_one })
  let removed = ($after_one | where {|x| $x not-in $after_two })
  if ($added | is-empty) and ($removed | is-empty) {
    print "PASS: pass two changed NOTHING — every path and every symlink target identical"
    $results = ($results | append true)
  } else {
    print "FAIL: pass two changed the tree"
    for a in $added { print $"      appeared/changed: ($a)" }
    for r in $removed { print $"      vanished/changed: ($r)" }
    $results = ($results | append false)
  }

  # And the specific shapes that were wrong, asserted by name so a regression
  # says WHICH one rather than only that something moved.
  # clang-tidy, NOT clangd: the re-versioning loop globs `clang-*`, which needs
  # the hyphen, so clangd is never touched by it. (Asserting on clangd was this
  # harness FAILING ON ITS OWN WRONG EXPECTATION the first time it ran.)
  let clangd = $"($root)/bin/clang-tidy"
  let clangd_target = (if (($clangd | path type) == "symlink") { (ls -l $clangd | get 0.target | path basename) } else { "" })
  if $clangd_target == "clang-tidy-21" and (($"($root)/bin/clang-tidy-21" | path type) == "file") {
    print "PASS: the re-versioned driver is still a symlink to a REAL binary after two passes"
    $results = ($results | append true)
  } else {
    print $"FAIL: bin/clangd -> '($clangd_target)' and clangd-21 is '($"($root)/bin/clangd-21" | path type)' — the self-referential-symlink defect"
    $results = ($results | append false)
  }

  let flang_cfg = (glob $"($root)/bin/*-flang.cfg")
  if not ($flang_cfg | is-empty) {
    let n = (open --raw ($flang_cfg | first) | lines | where {|l| $l != "" } | length)
    let uniq = (open --raw ($flang_cfg | first) | lines | where {|l| $l != "" } | uniq | length)
    if $n == $uniq {
      print $"PASS: the flang config file has ($n) lines and no duplicates after two passes"
      $results = ($results | append true)
    } else {
      print $"FAIL: the flang config file has ($n) lines but only ($uniq) distinct — it accumulates per pass"
      $results = ($results | append false)
    }
  }

  let bad = ($results | where {|r| not $r } | length)
  print ""
  print $"($results | length) idempotence behaviours exercised, ($bad) did not behave"
  if $bad > 0 { error make {msg: $"($bad) stage fixup\(s\) are not idempotent"} }
  print "EVERY STAGE FIXUP IS A NO-OP ON A SECOND PASS"
}
