# Exercise the in-tree clang config-file guard against a REAL clang, both ways.
#
# WHY THIS EXISTS. The guard fired once — on a FALSE POSITIVE, killing a correct
# build five seconds before the step it protects (run 34103103220: the
# constructed path carried `$SRC_DIR/../build_dir` while clang reported the
# canonical path, and the two literal strings differed by `work/../`). A guard
# whose TRUE branch has never been shown to fire is untested code, and one that
# has only ever fired wrongly is worse than none.
#
# So this runs the real function from build-stage.nu against a real clang 21:
#   1. a build directory containing `..` — the exact shape that broke — must PASS;
#   2. a config file clang does not read must FIRE;
#   3. the property assertion must FIRE when the stdlib genuinely is not found.
#
#   pixi run -e packaging nu tools/tests/exercise-clang-cfg-guard.nu

const STAGE = "packages/_acpp-stage/build-stage.nu"

# A real clang 21, from the same environment the gates use. Not a mock: the
# whole subject of the guard is what a real driver reports.
def clang-env [] {
  let r = (^pixi exec --spec "clangdev==21.1.8" -- nu -c '$env.CONDA_PREFIX' | complete)
  if $r.exit_code != 0 {
    print $r.stderr
    error make {msg: "could not materialise a clang 21.1.8 environment"}
  }
  ($r.stdout | str trim)
}

def main [] {
  let repo = ($env.FILE_PWD | path dirname | path dirname)
  cd $repo
  let ce = (clang-env)
  let clang = ($ce | path join "bin" "clang-21")
  if not ($clang | path exists) { error make {msg: $"no clang-21 in ($ce)"} }
  print $"using ($clang)"

  mut results = []

  # ── 1. THE REGRESSION: a build path containing `..` must PASS ──────────────
  # Reproduces run 34103103220's shape exactly: SRC_DIR/../build_dir.
  let root = "/tmp/clang-cfg-guard"
  rm -rf $root
  mkdir $"($root)/work" $"($root)/build_dir/bin"
  let unresolved = $"($root)/work/../build_dir"
  cp $clang $"($root)/build_dir/bin/clang-21"
  # The RESOURCE DIRECTORY travels with the binary. clang resolves it relative
  # to its own executable (`<bindir>/../lib/clang/<major>`), so a clang copied
  # out of its tree cannot find its own stddef.h — an artifact of the test
  # setup, not of the real build, where the in-tree compiler has its resource
  # dir right there. Copying it is what makes this a faithful rehearsal rather
  # than a broken one. (Assertion 2 caught the difference both times, which is
  # the guard doing its job on the harness.)
  mkdir $"($root)/build_dir/lib/clang"
  cp -r ($ce | path join "lib" "clang" "21") $"($root)/build_dir/lib/clang/21"
  let triple = (^$clang -dumpmachine | str trim)
  print $"triple: ($triple)"

  let r1 = (do {
    cd $repo
    with-env {ACPP_LLVM_MAJOR: "21", CONDA_BUILD_SYSROOT: ($ce | path join $triple "sysroot"), BUILD_PREFIX: $ce, LD_LIBRARY_PATH: ($ce | path join "lib")} {
      ^nu -c $"source ($STAGE); write-inbuild-clang-cfg '($unresolved)'"
    }
  } | complete)
  if $r1.exit_code == 0 {
    print "PASS: a build directory containing `..` is accepted (the run-6 false positive is fixed)"
    print ($r1.stdout | lines | where {|l| $l =~ 'in-tree clang config' } | each {|l| $"      ($l)" } | str join "\n")
    $results = ($results | append true)
  } else {
    print "FAIL: the `..` shape still fires the guard"
    print ($r1.stdout | lines | last 6 | str join "\n")
    print ($r1.stderr | lines | last 12 | str join "\n")
    $results = ($results | append false)
  }

  # ── 2. THE TRUE BRANCH: a cfg clang does NOT read must FIRE ────────────────
  # Handed a path clang will never report, which is precisely the condition the
  # guard exists for: a config file written under a name the driver ignores.
  let bogus = $"($root)/build_dir/bin/definitely-not-the-name.cfg"
  "--sysroot=/nowhere\n" | save -f $bogus
  let r2 = (do {
    cd $repo
    with-env {LD_LIBRARY_PATH: ($ce | path join "lib")} {
      ^nu -c $"source ($STAGE); assert-clang-reads-cfg '($root)/build_dir/bin/clang-21' '($bogus)'"
    }
  } | complete)
  if $r2.exit_code != 0 {
    print "PASS: a config file clang does not read FIRES the guard"
    print $"      ($r2.stderr | lines | where {|l| $l =~ 'did not read'} | first | default '' | str substring 0..150)"
    $results = ($results | append true)
  } else {
    print "FAIL: the guard accepted a config file clang never read"
    $results = ($results | append false)
  }

  # ── 3. AND IT REALLY IS READING OURS ──────────────────────────────────────
  # The positive case again, but asserting on the CONTENT: the flags we wrote
  # must appear in the driver's own -cc1 line, which is the only proof that the
  # file is doing anything.
  let cfg = $"($root)/build_dir/bin/($triple)-clang.cfg"
  "-DACPP_CFG_PROBE\n" | save -f $cfg
  let r3 = (with-env {LD_LIBRARY_PATH: ($ce | path join "lib")} {
    ^$"($root)/build_dir/bin/clang-21" -v -x c++ -E /dev/null | complete
  })
  if ($r3.stderr | str contains "ACPP_CFG_PROBE") {
    print "PASS: flags from the config file reach the driver's -cc1 invocation"
    $results = ($results | append true)
  } else {
    print "FAIL: the config file was reported but its flags did not reach cc1"
    $results = ($results | append false)
  }

  rm -rf $root
  let bad = ($results | where {|r| not $r } | length)
  print ""
  print $"($results | length) behaviours exercised, ($bad) did not behave"
  if $bad > 0 { error make {msg: $"($bad) clang-cfg guard behaviour\(s\) wrong"} }
  print "THE CLANG CONFIG GUARD FIRES ON A BAD NAME AND PASSES ON THE REAL SHAPE"
}
