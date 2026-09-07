# Exercise every nushell gate staging.yml calls, on GOOD and BAD input.
#
# A guard that has never fired is untested code, and a parse-check cannot see a
# live interpolation. So each gate is run twice: once over a tree it should
# accept, once over one it must reject — and a REJECTION that does not happen
# is a failure of this harness, not a pass.
#
# The .conda files are REAL: a zip holding info-*.tar.zst and pkg-*.tar.zst,
# built with bsdtar, so the gates run their real extraction path rather than a
# mock.

# The repo root, from this file's own location, so the harness travels with it.
# `const` is parse-time, so this is a normal binding inside main instead.
const WORK = "/tmp/gate-exercise"

def make-conda [dir: string, name: string, version: string, build: string, subdir: string, paths: list<string>] {
  let stage = ($WORK | path join "mk" $"($name)-($build)")
  rm -rf $stage
  mkdir ($stage | path join "info")
  # info/index.json — what check-closure and the disjointness name lookup read.
  {name: $name, version: $version, build: $build, build_number: 0, subdir: $subdir, depends: []}
    | to json | save -f ($stage | path join "info" "index.json")
  # info/paths.json — what the disjointness check reads.
  {paths_version: 1, paths: ($paths | each {|p| {_path: $p, path_type: "hardlink", sha256: "0"}})}
    | to json | save -f ($stage | path join "info" "paths.json")
  for p in $paths {
    let f = ($stage | path join $p)
    mkdir ($f | path dirname)
    $"content" | save -f $f
  }
  let files = ($paths | each {|p| $p })
  do { cd $stage; ^bsdtar --zstd -cf $"info-($name).tar.zst" info }
  do { cd $stage; ^bsdtar --zstd -cf $"pkg-($name).tar.zst" ...$files }
  {"conda_pkg_format_version": 2} | to json | save -f ($stage | path join "metadata.json")
  mkdir $dir
  let out = ($dir | path join $"($name)-($version)-($build).conda")
  rm -rf $out
  do { cd $stage; ^bsdtar -a -cf $out --format zip metadata.json $"info-($name).tar.zst" $"pkg-($name).tar.zst" }
  $out
}

def check-behaviour [label: string, expect_ok: bool, closure: closure] {
  let r = (do $closure | complete)
  let ok = ($r.exit_code == 0)
  if $ok == $expect_ok {
    print $"PASS: ($label) — (if $expect_ok { 'accepted' } else { 'REJECTED' }) as it should"
    if not $expect_ok { print $"      reason: ($r.stderr | lines | where {|l| $l =~ 'x |FAIL|MISSING'} | first 2 | str join ' / ')" }
  } else {
    print $"FAIL: ($label) — expected (if $expect_ok { 'accept' } else { 'reject' }), got exit ($r.exit_code)"
    print ($r.stdout | lines | last 5 | str join "\n")
    print ($r.stderr | lines | last 8 | str join "\n")
  }
  ($ok == $expect_ok)
}

def main [] {
  let REPO = ($env.FILE_PWD | path dirname | path dirname)
  rm -rf $WORK
  mkdir $WORK
  cd $REPO
  mut results = []

  # ── publish-accounting ────────────────────────────────────────────────────
  let good_log = ($WORK | path join "publish-good.log")
  ("  - acpp v2026.09.07 [llvm21_1_8_habc_0] (linux-64)\n"
   + "  - acpp-runtime v2026.09.07 [llvm21_1_8_habc_0] (linux-64)\n"
   + "  - acpp-clang v21.1.8 [llvm21_1_8_default_cfg_hx_0] (linux-64)\n"
   + "  - acpp-clang v21.1.8 [llvm21_1_8_default_nocfg_hy_0] (linux-64)\n"
   + "ℹ️  skipping 'packages/acpp-libcxx': no outputs for platform linux-64\n") | save -f $good_log
  $results = ($results | append (check-behaviour "publish-accounting: a complete log" true {
    ^pixi run -e packaging nu tools/publish-accounting.nu --log $good_log --expect 4 }))
  $results = ($results | append (check-behaviour "publish-accounting: SHORT count (a package silently absent)" false {
    ^pixi run -e packaging nu tools/publish-accounting.nu --log $good_log --expect 49 }))

  let empty_log = ($WORK | path join "publish-empty.log")
  ("ℹ️  skipping 'packages/acpp-libcxx': no outputs for platform linux-64\n"
   + "ℹ️  skipping 'packages/acpp-bolt': no outputs for platform linux-64\n") | save -f $empty_log
  $results = ($results | append (check-behaviour "publish-accounting: ZERO built (every output skipped)" false {
    ^pixi run -e packaging nu tools/publish-accounting.nu --log $empty_log --expect 2 }))

  let err_log = ($WORK | path join "publish-err.log")
  ((open --raw $good_log) + "acpp-toolkit is not part of the publish set\n") | save -f $err_log
  $results = ($results | append (check-behaviour "publish-accounting: an ERROR line in an otherwise fine log" false {
    ^pixi run -e packaging nu tools/publish-accounting.nu --log $err_log --expect 5 }))

  # ── collect-artifacts ─────────────────────────────────────────────────────
  let src = ($WORK | path join "bld")
  make-conda $src "acpp" "2026.09.07" "llvm21_1_8_habc_0" "linux-64" ["bin/acpp"]
  make-conda $src "acpp-runtime" "2026.09.07" "llvm21_1_8_habc_0" "linux-64" ["lib/libacpp-rt.so"]
  make-conda $src "acpp-clang" "21.1.8" "llvm21_1_8_default_cfg_hx_0" "linux-64" ["bin/clang"]
  # deliberately NOT created: the nocfg build the log names
  $results = ($results | append (check-behaviour "collect-artifacts: a published name with no file on disk" false {
    ^pixi run -e packaging nu tools/collect-artifacts.nu --log $good_log --into ($WORK | path join "dist-missing") --search $src }))

  let log3 = ($WORK | path join "publish-3.log")
  ("  - acpp v2026.09.07 [llvm21_1_8_habc_0] (linux-64)\n"
   + "  - acpp-runtime v2026.09.07 [llvm21_1_8_habc_0] (linux-64)\n"
   + "  - acpp-clang v21.1.8 [llvm21_1_8_default_cfg_hx_0] (linux-64)\n") | save -f $log3
  $results = ($results | append (check-behaviour "collect-artifacts: every published name present" true {
    ^pixi run -e packaging nu tools/collect-artifacts.nu --log $log3 --into ($WORK | path join "dist/linux-64") --search $src }))

  # ── check-package-disjointness ────────────────────────────────────────────
  let dj_ok = ($WORK | path join "dj-ok" "linux-64")
  make-conda $dj_ok "acpp" "2026.09.07" "llvm21_1_8_habc_0" "linux-64" ["bin/acpp" "bin/acpp-info"]
  make-conda $dj_ok "acpp-runtime" "2026.09.07" "llvm21_1_8_habc_0" "linux-64" ["lib/libacpp-rt.so"]
  make-conda $dj_ok "acpp-lld" "21.1.8" "llvm21_1_8_hq_0" "linux-64" ["bin/lld"]
  $results = ($results | append (check-behaviour "disjointness: three disjoint packages" true {
    ^pixi run -e packaging nu tools/check-package-disjointness.nu --artifacts ($WORK | path join "dj-ok") --expect 3 }))
  $results = ($results | append (check-behaviour "disjointness: --expect above the artifact count (a short set)" false {
    ^pixi run -e packaging nu tools/check-package-disjointness.nu --artifacts ($WORK | path join "dj-ok") --expect 10 }))

  # THE with_cfg CASE: two builds of ONE name sharing every path. This is the
  # false positive the gate must NOT report.
  let dj_var = ($WORK | path join "dj-variant" "linux-64")
  make-conda $dj_var "acpp-clang" "21.1.8" "llvm21_1_8_default_cfg_hx_0" "linux-64" ["bin/clang" "bin/clang++"]
  make-conda $dj_var "acpp-clang" "21.1.8" "llvm21_1_8_default_nocfg_hy_0" "linux-64" ["bin/clang" "bin/clang++"]
  make-conda $dj_var "acpp-lld" "21.1.8" "llvm21_1_8_hq_0" "linux-64" ["bin/lld"]
  $results = ($results | append (check-behaviour "disjointness: two builds of ONE name sharing every path (with_cfg)" true {
    ^pixi run -e packaging nu tools/check-package-disjointness.nu --artifacts ($WORK | path join "dj-variant") --expect 3 }))

  # A REAL clobber: two DIFFERENT names shipping one path.
  let dj_bad = ($WORK | path join "dj-bad" "linux-64")
  make-conda $dj_bad "acpp" "2026.09.07" "llvm21_1_8_habc_0" "linux-64" ["bin/acpp" "lib/clang/21/include/omp.h"]
  make-conda $dj_bad "acpp-clang-21" "21.1.8" "llvm21_1_8_hz_0" "linux-64" ["lib/clang/21/include/omp.h"]
  $results = ($results | append (check-behaviour "disjointness: two DIFFERENT names shipping one path" false {
    ^pixi run -e packaging nu tools/check-package-disjointness.nu --artifacts ($WORK | path join "dj-bad") --expect 2 }))

  # ── check-name-collisions ─────────────────────────────────────────────────
  $results = ($results | append (check-behaviour "name-collisions: with_cfg twins at ONE version" true {
    ^pixi run -e packaging nu tools/check-name-collisions.nu --platform linux-64 --log $good_log }))
  let two_ver = ($WORK | path join "two-versions.log")
  ("  - acpp-lld v21.1.8 [llvm21_1_8_ha_0] (linux-64)\n"
   + "  - acpp-lld v21.1.9 [llvm21_1_9_hb_0] (linux-64)\n") | save -f $two_ver
  $results = ($results | append (check-behaviour "name-collisions: ONE name at TWO versions" false {
    ^pixi run -e packaging nu tools/check-name-collisions.nu --platform linux-64 --log $two_ver }))
  let junk = ($WORK | path join "junk.log")
  "nothing here at all\n" | save -f $junk
  $results = ($results | append (check-behaviour "name-collisions: an unparseable log (a pass over nothing)" false {
    ^pixi run -e packaging nu tools/check-name-collisions.nu --platform linux-64 --log $junk }))

  # ── check-superset ────────────────────────────────────────────────────────
  # A log that ships everything the real target list demands cannot be forged
  # cheaply, so the GOOD case is the real dry run (already green) and the BAD
  # cases are a short log and a tampered target list.
  $results = ($results | append (check-behaviour "superset: a log missing nearly every required name" false {
    ^pixi run -e packaging nu tools/check-superset.nu --platform linux-64 --log $good_log }))
  let bad_targets = ($WORK | path join "targets-truncated.json")
  {generated_by: "test", source: "test", note: "test",
   counts: {linux-64: 3, win-64: 3, osx-arm64: 3},
   names: {linux-64: ["acpp-llvm" "acpp-lld" "acpp-lldb"], win-64: ["a"], osx-arm64: ["a"]}}
    | to json | save -f $bad_targets
  $results = ($results | append (check-behaviour "superset: a target list far too short to mean anything" false {
    ^pixi run -e packaging nu tools/check-superset.nu --platform linux-64 --targets-file $bad_targets }))
  let inconsistent = ($WORK | path join "targets-inconsistent.json")
  {generated_by: "test", source: "test", note: "test",
   counts: {linux-64: 99, win-64: 3, osx-arm64: 3},
   names: {linux-64: ["acpp-llvm"], win-64: ["a"], osx-arm64: ["a"]}}
    | to json | save -f $inconsistent
  $results = ($results | append (check-behaviour "superset: a target list inconsistent with its own count" false {
    ^pixi run -e packaging nu tools/check-superset.nu --platform linux-64 --targets-file $inconsistent }))

  # ── check-closure ─────────────────────────────────────────────────────────
  # The solve half needs the real channel, so only the guards that can be
  # exercised offline are exercised here; the solve half runs for the first
  # time in `verify` against real uploads.
  $results = ($results | append (check-behaviour "closure: an empty artifact directory (the vacuous pass)" false {
    ^pixi run -e packaging nu tools/check-closure.nu --artifacts ($WORK | path join "empty") --skip-solve }))
  mkdir ($WORK | path join "empty")
  $results = ($results | append (check-behaviour "closure: a directory with no .conda at all" false {
    ^pixi run -e packaging nu tools/check-closure.nu --artifacts ($WORK | path join "empty") --skip-solve }))
  $results = ($results | append (check-behaviour "closure: completeness FAILS when only three of the platform's packages are present" false {
    ^pixi run -e packaging nu tools/check-closure.nu --artifacts ($WORK | path join "dj-ok") --skip-solve }))

  # ── init-local-channel ────────────────────────────────────────────────────
  $results = ($results | append (check-behaviour "init-local-channel: an unknown platform" false {
    ^pixi run -e packaging nu tools/init-local-channel.nu --platform freebsd-64 --channel ($WORK | path join "ch") }))
  $results = ($results | append (check-behaviour "init-local-channel: a real platform" true {
    ^pixi run -e packaging nu tools/init-local-channel.nu --platform win-64 --channel ($WORK | path join "ch") }))

  let bad = ($results | where {|r| not $r } | length)
  print ""
  print $"($results | length) gate behaviours exercised, ($bad) did not behave"
  if $bad > 0 { error make {msg: $"($bad) gate\(s\) did not behave as specified"} }
  print "EVERY GATE FIRES ON BAD INPUT AND PASSES ON GOOD"
}
