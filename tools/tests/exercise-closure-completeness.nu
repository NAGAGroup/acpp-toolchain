# Exercise check-closure's COMPLETENESS half against real .conda artifacts,
# both ways.
#
# WHY THIS EXISTS. The completeness check counted only artifacts whose subdir
# equals the platform, while a platform job's declared set includes the
# `noarch: generic` packages it produces — which land in `noarch/`. Run
# 34124086049 therefore reported acpp-compiler-rt_linux-64 and
# acpp-compiler-rt21_linux-64 missing from a channel whose repodata the SAME
# run had just solved them from, one section below in the same output. The
# gate's model was wrong, not the tree.
#
# The fixture is two REAL packages built by rattler-build — one arch, one
# noarch — because the subdir under test is read out of each artifact's own
# index, and a hand-written file would not have one.
#
#   pixi run -e packaging nu tools/tests/exercise-closure-completeness.nu

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

const ROOT = "/tmp/closure-completeness"

def build-fixture [] {
  rm -rf $ROOT
  mkdir $"($ROOT)/recipes" $"($ROOT)/dist"
  # An architecture-specific package.
  'package:
  name: fixture-arch
  version: 1.0.0
build:
  number: 0
  script:
    - mkdir -p $PREFIX/bin && echo arch > $PREFIX/bin/fixture-arch
about:
  license: MIT
' | save -f $"($ROOT)/recipes/arch.yaml"
  # And a noarch one, which lands in noarch/ whoever builds it.
  'package:
  name: fixture-noarch
  version: 1.0.0
build:
  number: 0
  noarch: generic
  script:
    - mkdir -p $PREFIX/share && echo noarch > $PREFIX/share/fixture-noarch
about:
  license: MIT
' | save -f $"($ROOT)/recipes/noarch.yaml"

  for r in ["arch" "noarch"] {
    # Through `pixi run -e dev`, the pattern every other tool here uses: the
    # packaging environment has no rattler-build, and this repo has no `dev`
    # FEATURE to hang a task on — only an environment.
    let out = (^pixi run -e dev rattler-build build --recipe $"($ROOT)/recipes/($r).yaml" --output-dir $"($ROOT)/out" --target-platform linux-64 | complete)
    if $out.exit_code != 0 {
      print ($out.stderr | lines | last 10 | str join "\n")
      error make {msg: $"fixture: could not build the ($r) package"}
    }
  }
  # Flattened into one directory, exactly as collect-artifacts leaves them —
  # which is the point: the subdir must come from the ARTIFACT, not the path.
  for f in (glob-native $"($ROOT)/out/**/*.conda") { cp $f $"($ROOT)/dist/($f | path basename)" }
  print $"fixture: ($ROOT)/dist holds (ls $"($ROOT)/dist" | length) artifact\(s\), flattened"
}

# The completeness rule under test, lifted to operate on a declared list we
# control. Mirrors check-closure.nu's expression exactly.
def present-names [staged: list, platform: string] {
  $staged | where {|a| $a.subdir == $platform or $a.subdir == "noarch" } | get name | uniq | sort
}

def main [] {
  cd ($env.FILE_PWD | path dirname | path dirname)
  build-fixture

  # Read each artifact's own recorded subdir, the way check-closure does.
  let staged = (glob-native $"($ROOT)/dist/*.conda" | each {|p|
    let idx = (^pixi run -e packaging bsdtar -xOf $p "info-*.tar.zst" | ^pixi run -e packaging bsdtar -xOf - "info/index.json" | from json)
    {path: $p, name: $idx.name, subdir: $idx.subdir}
  })
  print $"fixture subdirs: ($staged | each {|s| $"($s.name)=($s.subdir)" } | str join ', ')"
  if ($staged | where {|s| $s.subdir == "noarch" } | is-empty) {
    error make {msg: "fixture: the noarch package did not record subdir=noarch — the fixture cannot test what it claims to"}
  }

  mut results = []
  let declared = ["fixture-arch" "fixture-noarch"]

  # ── 1. both present: must PASS, and the noarch one must be counted ────────
  let present = (present-names $staged "linux-64")
  let missing = ($declared | where {|d| $d not-in $present })
  if ($missing | is-empty) {
    print "PASS: a noarch package declared for linux-64 counts as present"
    $results = ($results | append true)
  } else {
    print $"FAIL: still reported missing: ($missing | str join ', ')"
    $results = ($results | append false)
  }

  # ── 2. drop the noarch artifact: must FAIL, naming it ─────────────────────
  let without = ($staged | where {|s| $s.subdir != "noarch" })
  let present2 = (present-names $without "linux-64")
  let missing2 = ($declared | where {|d| $d not-in $present2 })
  if ($missing2 == ["fixture-noarch"]) {
    print "PASS: removing the noarch artifact is still detected, by name"
    $results = ($results | append true)
  } else {
    print $"FAIL: expected exactly [fixture-noarch] missing, got [($missing2 | str join ', ')]"
    $results = ($results | append false)
  }

  # ── 3. and an arch artifact from ANOTHER platform must not satisfy it ─────
  let foreign = ($staged | each {|s| if $s.subdir == "linux-64" { {path: $s.path, name: $s.name, subdir: "win-64"} } else { $s } })
  let present3 = (present-names $foreign "linux-64")
  if ("fixture-arch" not-in $present3) {
    print "PASS: an artifact from another platform does not satisfy this platform"
    $results = ($results | append true)
  } else {
    print "FAIL: a win-64 artifact was counted as present for linux-64"
    $results = ($results | append false)
  }

  let bad = ($results | where {|r| not $r } | length)
  print ""
  print $"($results | length) completeness behaviours exercised, ($bad) did not behave"
  if $bad > 0 { error make {msg: $"($bad) closure-completeness behaviour\(s\) wrong"} }
  print "COMPLETENESS COUNTS noarch/ AND STILL CATCHES A REAL ABSENCE"
}