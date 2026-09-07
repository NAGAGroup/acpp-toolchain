# observe-first-build.nu — the questions only a real build can answer.
#
# OBSERVATIONS, NOT GATES. Every one of these is something the design left open
# and a render cannot see; each prints what it found and NONE of them fails the
# run. The answers belong in the log of the run that produced them rather than
# in somebody's memory.
#
# WHY THIS IS A FILE AND NOT INLINE `nu -c` IN THE WORKFLOW. The first two were
# inline, and both were broken in run 34101077994 for reasons that only appear
# at run time inside a YAML string:
#
#   * `$"... ($hits | length) package(s)"` — `(s)` inside an interpolated
#     string is a SUBEXPRESSION, so nushell tried to run a command called `s`
#     and suggested `ls`. The same trap has now cost this project three
#     separate one-liners.
#   * `glob ... | first` on an empty result — "can't convert nothing to
#     string". On a RED run nothing has been built, which is precisely when the
#     observations are read.
#
# In a file they are parse-checked with every other script, they can be run
# against a local dist/ before they ever reach a runner, and each is guarded
# for the empty case, which is the NORMAL case on a failed run.

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

def header [text: string] {
  print ""
  print $"=== ($text) ==="
}

# Every path a .conda ships, without unpacking it.
def conda-paths [artifact: string] {
  ^bsdtar -xOf $artifact "info-*.tar.zst" | ^bsdtar -xOf - "info/paths.json" | from json | get paths | get _path
}

def conda-index [artifact: string] {
  ^bsdtar -xOf $artifact "info-*.tar.zst" | ^bsdtar -xOf - "info/index.json" | from json
}

def main [--dist: string = "dist", --stage-run-log: string = "", --publish-log: string = "publish.log"] {
  let artifacts = (glob-native $"($dist)/**/*.conda")
  print $"observe: ($artifacts | length) artifact\(s\) under ($dist)"

  # 1. DID THE EXPENSIVE STAGE BUILD RUN EXACTLY ONCE? The whole cost model of
  # this workspace rests on that claim and it cannot be measured from inside
  # the build tree. Each execution appends one unique line to a file OUTSIDE it.
  header "how many times did the stage build run? (design says once per platform)"
  if $stage_run_log == "" or not ($stage_run_log | path exists) {
    print "no stage-run log — the build did not reach the stage, or ACPP_STAGE_RUN_LOG was unset"
  } else {
    let runs = (open --raw $stage_run_log | lines | where {|l| ($l | str trim) != "" } | uniq)
    print $"($runs | length) distinct execution\(s\)"
    for r in $runs { print $"  ($r)" }
  }

  # 2. WHICH OPTIONAL SLICE PATHS WERE ABSENT. install_openmp and install_bolt
  # both carry a REQUIRED list and an OPTIONAL one, and log the optional paths
  # the stage did not produce. That log line is what those lists get tightened
  # against — the alternative is guessing at what an LLVM build installs.
  header "optional slice paths that were ABSENT (tighten the lists against these)"
  if not ($publish_log | path exists) {
    print $"no ($publish_log)"
  } else {
    let lines = (open --raw $publish_log | lines | where {|l| $l =~ 'optional paths ABSENT' })
    if ($lines | is-empty) { print "none reported — either every optional path was present, or no slicer ran" }
    for l in $lines { print $"  ($l | str trim)" }
  }

  # 3. share/gdb — libompd's gdb plugin. Group 7 deliberately left it unclaimed
  # (it is openmp content, and acpp-llvm-openmp's scope comes from conda-forge's
  # artifact, which does not carry it). If the stage produces it, it currently
  # ships nowhere.
  header "share/gdb: does anything ship it?"
  if ($artifacts | is-empty) {
    print "no artifacts to inspect"
  } else {
    let owners = ($artifacts | where {|f| (conda-paths $f) | any {|p| $p =~ 'share/gdb' } })
    if ($owners | is-empty) {
      print "no package ships share/gdb — if the stage produced it, it is going unpackaged"
    } else {
      for o in $owners { print $"  shipped by ($o | path basename)" }
    }
  }

  # 4. WINDOWS: where does AdaptiveCpp put its runtime JSON? win's acpp-runtime
  # carve has no etc/AdaptiveCpp entry, because a carve glob matching nothing
  # FAILS the build and nobody has seen a Windows install tree.
  header "win: AdaptiveCpp's etc/ content, wherever it landed"
  if ($artifacts | is-empty) {
    print "no artifacts to inspect"
  } else {
    let hits = ($artifacts | each {|f|
      let etc = ((conda-paths $f) | where {|p| $p =~ 'AdaptiveCpp' and ($p =~ 'etc/' or $p =~ '\.json$') })
      if ($etc | is-empty) { null } else { {pkg: ($f | path basename), paths: ($etc | first 6)} }
    } | compact)
    if ($hits | is-empty) { print "no AdaptiveCpp etc/ or .json paths in any artifact" }
    for h in $hits { print $"  ($h.pkg): ($h.paths | str join ', ')" }
  }

  # 5. llvm-spirv's RPATH after rattler-build's post-processing. The tool sets
  # NO_INSTALL_RPATH when built externally, so the binary relies on the
  # packaging step adding $ORIGIN/../lib. Upstream ships the same shape, so it
  # is expected to work — and it is the kind of thing that only fails on a
  # user's machine.
  header "llvm-spirv: the RPATH baked into the shipped binary"
  let spirv = (glob-native $"($dist)/**/acpp-llvm-spirv-*.conda")
  if ($spirv | is-empty) {
    print "no acpp-llvm-spirv artifact — nothing built, or it is named differently"
  } else {
    let f = ($spirv | first)
    print $"  from ($f | path basename)"
    let out = (do { ^bsdtar -xOf $f "pkg-*.tar.zst" | ^bsdtar -xOf - --include "*/llvm-spirv" | ^rg -a -o '\$ORIGIN[^\u{0}]*' } | complete)
    if $out.exit_code != 0 or ($out.stdout | str trim) == "" {
      print "  no $ORIGIN entry found (the binary may be static, stripped, or absent from the archive)"
    } else {
      for l in ($out.stdout | lines | uniq) { print $"  ($l)" }
    }
  }

  # 5b. THE ROCm PREBUILTS AND rattler's PATCHELF FALLBACK. Six libraries from
  # the TheRock tarball — libamd_comgr, libhiprtc, libhiprtc-builtins,
  # libhsa-runtime64, librocprofiler-register, libamdhip64 — are third-party
  # ELF files we do not build, and rattler's in-place rpath rewrite cannot
  # patch them ("error new value is longer than old value"): its own edit can
  # only shrink a string in place, and our runtime prefix is longer than the
  # build placeholder. It then relinks each one with patchelf, which CAN grow
  # the section, and the archive writes normally (run 34103908648: six errors,
  # six patchelf relinks, same six names).
  #
  # So the error is rattler's FIRST ATTEMPT, not a failure — but the fallback's
  # RESULT has never been read. These libraries ship in acpp-runtime-rocm, and
  # a wrong rpath here is a runtime defect on a user's machine, so print what
  # actually got baked in.
  header "ROCm prebuilts: the RPATH patchelf left behind"
  let rocm = (glob-native $"($dist)/**/acpp-runtime-rocm-*.conda")
  if ($rocm | is-empty) {
    print "no acpp-runtime-rocm artifact in this run"
  } else {
    let f = ($rocm | first)
    print $"  from ($f | path basename)"
    let libs = ((conda-paths $f) | where {|p| $p =~ 'lib/lib(amdhip64|hiprtc|hsa-runtime64|amd_comgr|rocprofiler-register)' })
    print $"  ($libs | length) ROCm libraries shipped"
    let out = (do { ^bsdtar -xOf $f "pkg-*.tar.zst" | ^bsdtar -xOf - --include "*/libamdhip64*" | ^rg -a -o '\$ORIGIN[^\u{0}]*' } | complete)
    if $out.exit_code != 0 or ($out.stdout | str trim) == "" {
      print "  no $ORIGIN entry read back from libamdhip64 (it may carry an absolute RPATH, or none)"
    } else {
      for l in ($out.stdout | lines | uniq) { print $"  libamdhip64 RPATH: ($l)" }
    }
  }

  # 6. THE osx DEPLOYMENT FLOOR, read from a BUILT artifact rather than from
  # variants.yaml. c_stdlib_version 11.0 is load-bearing: the channel's
  # deployment-target package is at 26.0 and strong-exports __osx >= its own
  # version, so a wrong pin ships packages nobody can install.
  header "osx: the __osx floor actually recorded in the artifacts"
  let osx = (glob-native $"($dist)/osx-arm64/*.conda")
  if ($osx | is-empty) {
    print "no osx-arm64 artifacts in this run"
  } else {
    for f in ($osx | first 8) {
      let d = ((conda-index $f) | get depends | where {|x| $x =~ '__osx' })
      if not ($d | is-empty) { print $"  ($f | path basename): ($d | str join ', ')" }
    }
  }

  # 7. THE TEMPLATED NAMES: did they build from their sibling manifests, or
  # resolve from a channel? The manifest-name law is new and this is how it is
  # confirmed on a real run rather than on a probe.
  header "templated names: acpp-*_<platform> in the publish log"
  if not ($publish_log | path exists) {
    print $"no ($publish_log)"
  } else {
    let lines = (open --raw $publish_log | lines
      | where {|l| $l =~ 'acpp-(compiler-rt|clang|clangxx)(21)?(_impl)?_(linux-64|win-64|osx-arm64)' }
      | first 20)
    if ($lines | is-empty) { print "none named in the log" }
    for l in $lines { print $"  ($l | str trim)" }
  }

  print ""
  print "observe: done — every line above is an observation, none of them gated this run"
}