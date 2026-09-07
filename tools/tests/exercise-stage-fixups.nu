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

const STAGE = "packages/_acpp-stage/build-stage.nu"

# A synthetic stage tree with the shapes the fixups act on: versioned and
# unversioned clang drivers, the openmp headers in the resource directory where
# an in-tree build puts them, clang's own headers beside them, the compiler-rt
# runtimes, libgomp and libarcher.
# ⚠ THE FIXTURE IS BUILT IN THE SHAPE OF THE PLATFORM UNDER TEST. It used to be
# linux-shaped unconditionally, while the fixups branch on the OS — so on a mac
# runner the darwin fixup met a linux tree and fired its own loud-empty guard
# against the fixture, failing gate 1b in under two minutes (osx run
# 34128626319). The harness was wrong, not the stage. A fixture that does not
# match the branch it feeds is testing nothing.
#
# `os` is the value the fixups themselves read through ACPP_FAKE_OS, so the
# tree and the branch cannot disagree.
def make-tree [root: string, os: string] {
  rm -rf $root
  let rt_dir = (if $os == "macos" { "darwin" } else if $os == "windows" { "windows" } else { "linux" })
  mkdir $"($root)/bin" $"($root)/lib" $"($root)/lib/clang/21/include" $"($root)/lib/clang/21/lib/($rt_dir)"

  # The drivers the re-versioning loop and the symlink farm act on. `.exe` on
  # Windows, because that loop globs `clang-*` and the win fixups look for
  # names with the extension.
  let exe = (if $os == "windows" { ".exe" } else { "" })
  for n in ["clang-21" "clang-tidy" "clang-format" "clang-scan-deps-21" "clang-offload-packager-21" "clangd"] {
    $"#!/bin/sh\n# ($n)\n" | save -f $"($root)/bin/($n)($exe)"
  }

  # OpenMP headers in the resource dir, where an in-tree build puts them, plus
  # clang's own headers beside them — the move must take the first and leave
  # the second, on every platform.
  for n in ["omp.h" "ompx.h" "omp-tools.h" "ompt.h" "ompt-multiplex.h"] {
    $"// openmp ($n)\n" | save -f $"($root)/lib/clang/21/include/($n)"
  }
  for n in ["stddef.h" "immintrin.h"] {
    $"// clang ($n)\n" | save -f $"($root)/lib/clang/21/include/($n)"
  }

  # The compiler-rt runtimes, in each platform's own spelling: the shared
  # sanitizer libraries the post-install copy moves, plus a static archive that
  # must NOT be copied.
  let rt_ext = (if $os == "macos" { ".dylib" } else if $os == "windows" { ".dll" } else { ".so" })
  let rt_prefix = (if $os == "windows" { "clang_rt." } else { "libclang_rt." })
  for n in ["asan" "tsan" "ubsan_standalone"] {
    $"// rt\n" | save -f $"($root)/lib/clang/21/lib/($rt_dir)/($rt_prefix)($n)($rt_ext)"
  }
  let static_ext = (if $os == "windows" { ".lib" } else { ".a" })
  $"// builtins\n" | save -f $"($root)/lib/clang/21/lib/($rt_dir)/($rt_prefix)builtins($static_ext)"

  # openmp-install-fixups is unix-only in the stage, so its inputs are too.
  if $os != "windows" {
    let so = (if $os == "macos" { ".dylib" } else { ".so" })
    $"// gomp\n" | save -f $"($root)/lib/libgomp($so)"
    if $os == "linux" { "// archer\n" | save -f $"($root)/lib/libarcher.so" }
  }
  # The versioned libLTO the darwin clang fixup links into the resource dir.
  if $os == "macos" { "// lto\n" | save -f $"($root)/lib/libLTO.21.1.dylib" }

  # What the WINDOWS clang fixup reads: the unversioned driver it copies to the
  # versioned names, and the libclang DLL whose SOVERSION patch 0007 fixes at
  # 13. Both are real install products of an LLVM Windows build; the fixup
  # errors by design if the DLL is absent, so a fixture without them tests the
  # guard rather than the fixup.
  if $os == "windows" {
    "// clang driver\n" | save -f $"($root)/bin/clang.exe"
    "// libclang\n" | save -f $"($root)/bin/libclang-13.dll"
  }
}

# The tree's full state: every path, plus what each symlink points at. Two
# snapshots being equal is what "changed nothing" means.
def snapshot [root_in: string] {
  # ⚠ BOTH SIDES FORWARD-SLASH. glob-native returns normalised results; the root
  # they are made relative to must be normalised as well, or on Windows
  # `path relative-to` fails with "prefix not found" against a mixed pair like
  # `/tmp/stage-fixups-windows\bin` vs `/tmp/stage-fixups-windows`. That is how
  # win run 34134434830 died — in this snapshot, AFTER the fixups themselves had
  # passed on a real Windows runner for the first time.
  let root = $root_in
  glob-native $"($root)/**/*" --no-dir
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

# The fixup sequence the stage runs after `cmake --install`, in the same order
# and with the same branch for the platform under test. Windows takes
# clang-install-fixups-WIN and has no openmp-install-fixups — mirroring
# build-stage.nu exactly, because a harness that ran a different sequence would
# be testing a program we do not ship.
#
# ACPP_FAKE_OS is set INSIDE the child, so the sourced predicates see it.
def run-fixups [root: string, os: string] {
  let clang_fixup = (if $os == "windows" {
    $"clang-install-fixups-win '($root)'"
  } else {
    $"clang-install-fixups-unix '($root)'"
  })
  let openmp_fixup = (if $os == "windows" { "" } else { $"; openmp-install-fixups '($root)'" })
  # ⚠ ONE EXTERNAL IS STUBBED WHENEVER THIS HARNESS RUNS THE WINDOWS BRANCH —
  # on a Windows runner too, and that correction matters. The condition used to
  # be "we are faking an OS", which is the wrong axis: on a real win runner the
  # branch calls the real `create-forwarder-dll`, and that tool lives in the
  # STAGE's build environment while this gate runs in `packaging`. Win run
  # 34130056510 failed with `Command 'create-forwarder-dll' not found` for
  # exactly that reason — the harness must never need a build-env tool, on any
  # platform.
  #
  # It is the ONLY one: audited, the four fixups this runs call `ln` (coreutils,
  # present everywhere, and load-bearing for the symlink behaviour under test)
  # and nothing else external. A DLL forwarder we neither own nor test is a
  # legitimate stand-in; `ln` would not be.
  # ⚠ AND THE STUB ITSELF IS WRITTEN FOR BOTH HOSTS. A `#!/bin/sh` file with
  # `chmod +x` is not executable on Windows — where this branch now also runs —
  # and `chmod` does not exist there either. So: a shell script for a unix host
  # forcing the win branch, and a `.bat` for a real win runner, which is what
  # PATHEXT will find. Writing only the first would have been the same
  # platform-blindness one level down from the bug being fixed.
  let stub_dir = $"($root)-stubs"
  if $os == "windows" {
    rm -rf $stub_dir
    mkdir $stub_dir
    if $nu.os-info.name == "windows" {
      # %2 is the forwarder path the fixup asks for; creating it empty is all
      # the harness needs, since what is under test is our logic around it.
      "@echo off\r\nrem fixture stub for create-forwarder-dll\r\ntype nul > %2\r\n" | save -f $"($stub_dir)/create-forwarder-dll.bat"
    } else {
      "#!/bin/sh\n# fixture stub for create-forwarder-dll: writes the forwarder it is asked for\ntouch \"$2\"\n" | save -f $"($stub_dir)/create-forwarder-dll"
      ^chmod +x $"($stub_dir)/create-forwarder-dll"
    }
  }
  let path_extra = (if ($stub_dir | path exists) { [$stub_dir] } else { [] })
  with-env {PATH: ($path_extra | append $env.PATH)} {
    ^nu -c $"$env.ACPP_FAKE_OS = '($os)'; source ($STAGE); compiler-rt-install-fixups '($root)' '($root)'; openmp-header-fixups '($root)' '($root)'; ($clang_fixup)($openmp_fixup)"
  }
}

def main [--os: string = ""] {
  cd ($env.FILE_PWD | path dirname | path dirname)
  # Default: the platform this is running on, which is what CI wants. `--os`
  # forces another, which is how all three branches get exercised from one
  # laptop before a metered runner sees them.
  let os = (if $os == "" { $nu.os-info.name } else { $os })
  let root = $"/tmp/stage-fixups-($os)"
  print $"exercising the ($os) fixups"
  mut results = []

  make-tree $root $os
  let p1 = (with-env {ACPP_LLVM_MAJOR: "21", ACPP_LLVM_MAJ_MIN: "21.1", CONDA_BUILD_SYSROOT: "", BUILD_PREFIX: ""} { run-fixups $root $os | complete })
  if $p1.exit_code != 0 {
    print "FAIL: the fixups do not survive their FIRST pass on a clean tree"
    print ($p1.stderr | lines | last 12 | str join "\n")
    error make {msg: "stage fixups failed on pass one"}
  }
  print "PASS: pass one succeeds on a clean tree"
  print ($p1.stdout | lines | each {|l| $"      ($l)" } | str join "\n")
  let after_one = (snapshot $root)

  # THE ASSERTION. A cached run re-executes everything against this tree.
  let p2 = (with-env {ACPP_LLVM_MAJOR: "21", ACPP_LLVM_MAJ_MIN: "21.1", CONDA_BUILD_SYSROOT: "", BUILD_PREFIX: ""} { run-fixups $root $os | complete })
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
  #
  # ⚠ PER PLATFORM, because the two branches produce DIFFERENT shapes and
  # asserting one against the other is testing a program we do not ship. Unix
  # re-versions by moving the binary and leaving a symlink; Windows copies
  # clang.exe to the versioned names and creates no symlinks at all. Asserting
  # the unix shape on windows was this harness failing on its own wrong
  # expectation for the SECOND time — the first was asserting on `clangd`,
  # which the `clang-*` glob never matches.
  if $os == "windows" {
    # The win fixup COPIES: both versioned names must be real files, and pass
    # two must not have replaced either with something else.
    let copies = ["clang-21.exe" "clang++-21.exe"]
    let types = ($copies | each {|n| ($"($root)/bin/($n)" | path type) })
    if ($types | all {|t| $t == "file" }) {
      print $"PASS: the versioned drivers are still real files after two passes \(($copies | str join ', '))"
      $results = ($results | append true)
    } else {
      print $"FAIL: versioned drivers are ($types | str join ', ') — expected real files"
      $results = ($results | append false)
    }
  } else {
    # clang-tidy, NOT clangd: the re-versioning loop globs `clang-*`, which
    # needs the hyphen, so clangd is never touched by it.
    let driver = $"($root)/bin/clang-tidy"
    let target = (if (($driver | path type) == "symlink") { (ls -l $driver | get 0.target | path basename) } else { "" })
    if $target == "clang-tidy-21" and (($"($root)/bin/clang-tidy-21" | path type) == "file") {
      print "PASS: the re-versioned driver is still a symlink to a REAL binary after two passes"
      $results = ($results | append true)
    } else {
      print $"FAIL: bin/clang-tidy -> '($target)' and clang-tidy-21 is '($"($root)/bin/clang-tidy-21" | path type)' — the self-referential-symlink defect"
      $results = ($results | append false)
    }
  }

  let flang_cfg = (glob-native $"($root)/bin/*-flang.cfg")
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

  # ⚠ EVERY SNAPSHOT PATH IS FORWARD-SLASH AND RELATIVE-TO SUCCEEDS. This is the
  # assertion that fires on a LAPTOP if a helper ever returns a Windows-spelled
  # path — the failure it guards is invisible on linux, where nothing produces a
  # backslash, so without it the only detector is a metered win runner.
  let mixed = ($after_two | where {|s| $s =~ '\\' })
  if ($mixed | is-empty) {
    print $"PASS: all ($after_two | length) snapshot paths are forward-slash and relative to the root"
    $results = ($results | append true)
  } else {
    print $"FAIL: ($mixed | length) snapshot path\(s\) carry a backslash — glob-native or the root is not normalised"
    for m in ($mixed | first 5) { print $"      ($m)" }
    $results = ($results | append false)
  }

  # ⚠ THE SEAM MUST STAY A TESTING SEAM. `ACPP_FAKE_OS` overrides the stage's
  # platform predicates, so a recipe or workflow setting it would make a real
  # build believe it was on another OS. It may appear only in build-stage.nu
  # (where it is read) and under tools/tests (where it is set).
  let leaks = (^git grep -l "ACPP_FAKE_OS" | complete | get stdout | lines
    | where {|f| $f != "" }
    | where {|f| not ($f | str starts-with "tools/tests/") }
    | where {|f| $f != "packages/_acpp-stage/build-stage.nu" })
  if ($leaks | is-empty) {
    print "PASS: ACPP_FAKE_OS appears only where it is read and where tests set it"
    $results = ($results | append true)
  } else {
    print $"FAIL: ACPP_FAKE_OS also appears in ($leaks | str join ', ') — a build must never read it"
    $results = ($results | append false)
  }

  let bad = ($results | where {|r| not $r } | length)
  print ""
  print $"($results | length) idempotence behaviours exercised, ($bad) did not behave"
  if $bad > 0 { error make {msg: $"($bad) stage fixup\(s\) are not idempotent"} }
  print "EVERY STAGE FIXUP IS A NO-OP ON A SECOND PASS"
}