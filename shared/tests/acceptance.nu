#!/usr/bin/env nu
# THE ACCEPTANCE ARTIFACT for the phase-3 redesign.
#
#   nu shared/tests/acceptance.nu [--channel <url>] [--version-spec <spec>]
#
# This is the thing a reviewer runs to be convinced, so it is deliberately
# hostile to false passes:
#
#   * FRESH WORKSPACE — created in a temp dir, nothing inherited from this repo.
#   * CLEAN CACHE — an isolated PIXI_CACHE_DIR/RATTLER_CACHE_DIR per case, so no
#     answer can come from a warm cache. This matters more than it sounds: the
#     rattler repodata cache has served stale channel answers before, and a
#     "pass" from a warm cache proves nothing about what a new user gets.
#   * SINGLE CHANNEL — only naga-labs. If the layering ever stops working, this
#     fails rather than being quietly rescued by a conda-forge entry.
#   * IT BUILDS, not just locks. A lock only proves the solver was happy; the
#     compile proves the toolchain that arrives actually works, and that the
#     run_exports put a usable runtime in the environment.
#
# Cases:
#   1. Plain semver range + default lane      -> locks AND compiles AND runs
#   2. Explicit lane pin (acpp-llvm ==<major>) -> locks, and selects that lane
#   3. Wrong-lane pin                          -> MUST fail to lock
#
# Case 3 is what makes 1 and 2 meaningful: without it, a suite that always
# solves would look identical to a correct one.

const DEFAULT_CHANNEL = "https://prefix.dev/jackm97/naga-labs"

def make-workspace [dir: path, channel: string, deps: list<string>] {
  let dep_lines = ($deps | each {|d|
    let parts = ($d | split row " " | where {|x| $x != "" })
    if ($parts | length) == 1 {
      $'($parts | first) = "*"'
    } else {
      $'($parts | first) = "($parts | skip 1 | str join " ")"'
    }
  } | str join "\n")

  $'[workspace]
name = "acceptance"
# ONE channel. naga-labs layers conda-forge server-side; if that ever stops
# being true this file is where it surfaces.
channels = ["($channel)"]
platforms = ["linux-64"]
channel-priority = "strict"

[dependencies]
($dep_lines)
' | save --force ($dir | path join "pixi.toml")
}

# Every case gets its own cache. Returns the env record to run pixi under.
def clean-env [dir: path] {
  let cache = ($dir | path join ".isolated-cache")
  mkdir $cache
  {PIXI_CACHE_DIR: $cache, RATTLER_CACHE_DIR: $cache}
}

def case-locks [name: string, channel: string, deps: list<string>, should_lock: bool] {
  let dir = (mktemp -d)
  make-workspace $dir $channel $deps
  let res = (with-env (clean-env $dir) { do { cd $dir; ^pixi lock --no-progress } | complete })
  let locked = ($res.exit_code == 0)
  let ok = ($locked == $should_lock)
  print $"[(if $ok { 'PASS' } else { 'FAIL' })] ($name) — locked=($locked) expected=($should_lock)"
  if not $ok { print ($res.stderr | lines | last 12 | str join "\n") }
  let lockfile = ($dir | path join "pixi.lock")
  let lock = (if $locked and ($lockfile | path exists) { open $lockfile | from yaml } else { null })
  {ok: $ok, dir: $dir, lock: $lock}
}

# Which acpp-llvm major did the lock actually select?
def locked-major [lock: any] {
  if $lock == null { return null }
  let urls = ($lock.environments.default.packages."linux-64"
    | each {|p| $p.conda? | default "" })
  let hit = ($urls | where {|u| ($u | path basename) =~ '^acpp-llvm-[0-9]+-' })
  if ($hit | is-empty) { return null }
  $hit | first | path basename | parse -r 'acpp-llvm-(?<maj>[0-9]+)-' | get maj.0
}

def main [--channel: string = $DEFAULT_CHANNEL, --version-spec: string = ">=25.10.0,<25.11.0a0"] {
  print $"acceptance: channel=($channel) spec='acpp ($version_spec)'"
  mut results = []

  # ── 1. the headline consumer: a plain semver range, no lane text at all ──
  let c1 = (case-locks "plain semver range + default lane" $channel [$"acpp ($version_spec)"] true)
  $results = ($results | append $c1.ok)

  mut default_major = null
  if $c1.ok and $c1.lock != null {
    $default_major = (locked-major $c1.lock)
    # The mutex must arrive WITHOUT being asked for — that is the whole point
    # of the export flip. If it is absent, lane selection is not being carried.
    let got = ($default_major != null)
    print $"[(if $got { 'PASS' } else { 'FAIL' })] mutex arrives unrequested — acpp-llvm major = ($default_major)"
    $results = ($results | append $got)
  }

  # ── 1b. it BUILDS and RUNS, not just locks ───────────────────────────────
  if $c1.ok {
    let src = ($env.FILE_PWD | path join "hello.cpp")
    let dir = $c1.dir
    cp $src ($dir | path join "hello.cpp")
    let build = (with-env (clean-env $dir) { do {
      cd $dir
      ^pixi run acpp -O2 --acpp-targets=generic hello.cpp -o ./hello
    } | complete })
    if $build.exit_code != 0 {
      print "[FAIL] fresh consumer COMPILES"
      print ($build.stderr | lines | last 20 | str join "\n")
      $results = ($results | append false)
    } else {
      print "[PASS] fresh consumer COMPILES"
      $results = ($results | append true)
      let run = (with-env (clean-env $dir) { do {
        cd $dir
        with-env {ACPP_VISIBILITY_MASK: "omp"} { ^./hello }
      } | complete })
      let ran = ($run.exit_code == 0)
      print $"[(if $ran { 'PASS' } else { 'FAIL' })] fresh consumer RUNS on the CPU backend"
      if not $ran { print ($run.stderr | lines | last 15 | str join "\n") }
      $results = ($results | append $ran)
    }
  }

  # ── 2. explicit lane selection ───────────────────────────────────────────
  if $default_major != null {
    let c2 = (case-locks $"explicit lane pin acpp-llvm ==($default_major)" $channel
      [$"acpp ($version_spec)" $"acpp-llvm ==($default_major)"] true)
    $results = ($results | append $c2.ok)
    if $c2.ok {
      let m = (locked-major $c2.lock)
      let same = ($m == $default_major)
      print $"[(if $same { 'PASS' } else { 'FAIL' })] explicit pin selected major ($m)"
      $results = ($results | append $same)
    }

    # ── 3. the wrong lane must be REFUSED ──────────────────────────────────
    # Without this, cases 1 and 2 would look identical to a suite that always
    # solves. `other` is a major this release lane is not built against.
    let other = (if $default_major == "20" { "21" } else { "20" })
    let c3 = (case-locks $"wrong-lane pin acpp-llvm ==($other) is refused" $channel
      [$"acpp ($version_spec)" $"acpp-llvm ==($other)"] false)
    $results = ($results | append $c3.ok)
  }

  let failed = ($results | where {|r| not $r } | length)
  if $failed > 0 {
    error make {msg: $"acceptance: ($failed) of ($results | length) checks FAILED"}
  }
  print $"acceptance: ALL ($results | length) CHECKS PASS"
}
