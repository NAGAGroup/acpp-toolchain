#!/usr/bin/env nu
# Publish gate: CLOSURE.
#
#   nu shared/check-closure.nu [channel_dir] [--remote <url>]
#
# Publishing a package name means OWNING it: every spec we ship must be
# satisfiable from the channel as consumers actually see it, and it must fail
# LOUD here rather than silently in someone else's solve.
#
# Two halves, because neither catches the other's failure:
#
#  1. COMPLETENESS (metadata vs artifact). Every output the recipes declare for
#     a platform must actually be present among the staged artifacts. This is
#     what catches a `files:` glob that stopped matching: the build stays green,
#     the package is simply absent or hollow, and nothing downstream notices
#     until a consumer asks for it. Derived from a fresh render rather than a
#     hard-coded list, so adding an output cannot leave the gate behind.
#
#  2. CLOSURE (fresh solve). Every staged artifact is solved for, pinned to its
#     exact version and build, against local-channel + the real channel under
#     strict priority — one throwaway workspace each, so nothing is satisfied
#     by a warm environment or a lockfile lying around. A package whose own
#     dependencies cannot be resolved is a package we must not publish.
#
# Runs alongside the C-11 collision probe and the mutex-version assert in every
# publish job.

const REMOTE = "https://prefix.dev/jackm97/naga-labs"

def conda-index [pkg: path] {
  let info_glob = "info-*.tar.zst"
  ^unzip -p $pkg $info_glob | ^zstd -d -q -c | ^tar -xO "info/index.json" | from json
}

def file-url [p: path] {
  let abs = ($p | path expand | str replace --all '\' '/')
  $"file:///($abs | str trim --left --char '/')"
}

# What the recipes SAY should exist for a platform, for the given lanes.
#
# Lanes are passed in rather than always being both: a release publish job
# stages only release artifacts, so demanding the nightly names there would
# fail a gate that is working correctly. The caller derives the lanes from what
# is actually staged.
def declared-outputs [platform: string, lanes: list<string>] {
  let variants = ([shared variants $"($platform).yaml"] | path join)
  $lanes | each {|lane|
    let recipe = ($lane | path join "recipe.yaml")
    if not ($recipe | path exists) { return [] }
    let res = (do {
      (^rattler-build build --recipe $recipe --experimental --render-only
        -m $variants --target-platform $platform)
    } | complete)
    if $res.exit_code != 0 {
      error make {msg: $"closure: could not render ($recipe) for ($platform) — cannot determine the declared output set"}
    }
    $res.stdout | from json | each {|o| $o.recipe.package.name }
  } | flatten | uniq | sort
}

def solve-one [platform: string, channels: list<string>, name: string, version: string, build: string] {
  let dir = (mktemp -d)
  let chan_lines = ($channels | each {|c| $'"($c)"' } | str join ", ")
  $'[workspace]
name = "closure"
channels = [($chan_lines)]
platforms = ["($platform)"]
channel-priority = "strict"

[dependencies]
"($name)" = { version = "==($version)", build = "($build)" }
' | save ($dir | path join "pixi.toml")
  let res = (do { cd $dir; ^pixi lock --no-progress } | complete)
  let ok = ($res.exit_code == 0)
  if not $ok {
    print $"[FAIL] closure: ($name) ($version) ($build) on ($platform) is UNSOLVABLE"
    print ($res.stderr | lines | last 12 | str join "\n")
  }
  rm -rf $dir
  $ok
}

def main [channel_dir: string = "local-channel", --remote: string = $REMOTE] {
  let artifacts = (glob $"($channel_dir)/**/*.conda")
  if ($artifacts | is-empty) {
    error make {msg: $"closure: no artifacts under ($channel_dir) — refusing to pass vacuously"}
  }

  # Subdir comes from the artifact metadata, never the directory layout: the
  # publish job flattens both platforms' channels into one directory.
  let staged = ($artifacts | each {|p|
    let i = (conda-index $p)
    {path: $p, name: $i.name, version: $i.version, build: $i.build, subdir: $i.subdir}
  })

  let platforms = ($staged | get subdir | uniq | where {|s| $s != "noarch" } | sort)
  print $"closure: ($staged | length) staged artifacts across ($platforms | str join ', ')"

  mut results = []

  # Which lanes are in this upload? A nightly package is exactly one whose name
  # carries the -nightly infix; the two lanes are separate package families, so
  # this is a naming fact rather than a heuristic.
  let has_nightly = ($staged | any {|a| $a.name | str contains "-nightly" })
  let has_release = ($staged | any {|a|
    (not ($a.name | str contains "-nightly")) and ($a.name != "acpp-llvm")
  })
  let lanes = ([(if $has_release { "release" }), (if $has_nightly { "nightly" })] | compact)
  print $"closure: lanes in this upload = ($lanes | str join ', ')"

  # ── 1. completeness ──────────────────────────────────────────────────────
  for p in $platforms {
    let declared = (declared-outputs $p $lanes)
    let present = ($staged | where {|a| $a.subdir == $p } | get name | uniq | sort)
    let missing = ($declared | where {|d| not ($d in $present) })
    let ok = ($missing | is-empty)
    print $"[(if $ok { 'PASS' } else { 'FAIL' })] completeness ($p): ($present | length) of ($declared | length) declared outputs present"
    if not $ok { print $"    MISSING: ($missing | str join ', ')" }
    $results = ($results | append $ok)
  }

  # ── 2. closure ───────────────────────────────────────────────────────────
  let chans = [(file-url $channel_dir), $remote]
  for a in $staged {
    # noarch packages are solved on every platform they can land on.
    let targets = (if $a.subdir == "noarch" { $platforms } else { [$a.subdir] })
    for t in $targets {
      let ok = (solve-one $t $chans $a.name $a.version $a.build)
      if $ok { print $"[PASS] closure: ($a.name) ($a.version) ($a.build) on ($t)" }
      $results = ($results | append $ok)
    }
  }

  let failed = ($results | where {|r| not $r } | length)
  if $failed > 0 {
    error make {msg: $"closure gate: ($failed) of ($results | length) checks FAILED — refusing to publish"}
  }
  print $"closure gate: all ($results | length) checks pass"
}
