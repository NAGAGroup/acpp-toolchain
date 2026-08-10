#!/usr/bin/env nu
# Sanitizer smoke for acpp-compiler-rt.
#
#   nu shared/tests/sanitizer-smoke.nu [--cxx acpp] [--workdir <dir>]
#
# Proves the compiler-rt runtimes we ship are usable, in two directions,
# because only the pair is meaningful:
#
#   1. A sanitized binary LINKS and RUNS clean (exit 0). This is what catches
#      the runtimes being absent or unfindable — the failure mode that made the
#      toolchain a non-drop-in replacement before phase 3.
#   2. The same binary, told to fault, ACTUALLY ABORTS. Without this the first
#      check passes just as happily against a sanitizer that was linked but
#      does nothing, which is a strictly worse outcome than not shipping one.
#
# Run from the smoke workspace so the toolchain comes from a real solve against
# the built channel, exactly as a consumer would get it.

def run-case [cxx: string, san: string, src: path, workdir: path] {
  let exe = ($workdir | path join $"sanitize-($san)")
  print $"── ($san): compiling"
  let build = (do {
    ^$cxx -O1 -g -fno-omit-frame-pointer $"-fsanitize=($san)" $src -o $exe
  } | complete)
  if $build.exit_code != 0 {
    print $"[FAIL] ($san): COMPILE/LINK failed — the runtime is missing or unfindable"
    print ($build.stderr | lines | last 20 | str join "\n")
    return false
  }

  # 1. clean run must exit 0 and report the sanitizer active
  let clean = (do { ^$exe } | complete)
  if $clean.exit_code != 0 {
    print $"[FAIL] ($san): sanitized binary did not run clean \(exit ($clean.exit_code)\)"
    print $clean.stdout
    print ($clean.stderr | lines | last 20 | str join "\n")
    return false
  }
  if not ($clean.stdout | str contains "ACTIVE") {
    print $"[FAIL] ($san): binary did not report the sanitizer active — built without it?"
    print $clean.stdout
    return false
  }
  print $"[PASS] ($san): links, runs clean, reports active"

  # 2. the fault must actually trip. ASan aborts; TSan's race detector is not
  # what this binary exercises, so only ASan is asked to prove the fault path.
  if $san == "address" {
    let faulted = (do { ^$exe --fault } | complete)
    if $faulted.exit_code == 0 {
      print "[FAIL] address: deliberate heap-buffer-overflow did NOT abort — the runtime is linked but inert"
      return false
    }
    let saw = ($"($faulted.stdout)($faulted.stderr)" | str contains "heap-buffer-overflow")
    if not $saw {
      print $"[FAIL] address: aborted \(exit ($faulted.exit_code)\) but without an ASan diagnostic"
      print ($faulted.stderr | lines | last 15 | str join "\n")
      return false
    }
    print "[PASS] address: deliberate overflow aborts with an ASan diagnostic"
  }
  true
}

def main [--cxx: string = "acpp", --workdir: string = ""] {
  let wd = (if $workdir == "" { mktemp -d } else { $workdir })
  # Resolved relative to this script so it works from the smoke workspace.
  let src = ($env.FILE_PWD | path join "sanitize.cpp")
  if not ($src | path exists) { error make {msg: $"sanitizer smoke: source not found at ($src)"} }

  mut ok = []
  for san in ["address" "thread"] {
    $ok = ($ok | append (run-case $cxx $san $src $wd))
  }

  let failed = ($ok | where {|r| not $r } | length)
  if $failed > 0 {
    error make {msg: $"sanitizer smoke: ($failed) of ($ok | length) cases FAILED"}
  }
  print "sanitizer smoke: ALL PASS"
}
