# check-closure.nu — publishing a name means OWNING it. Every artifact we
# published must be INSTALLABLE from the channel as a consumer sees it.
#
# PORTED from `main:shared/check-closure.nu`, which was written for the
# two-lane single-recipe tree. What survives is the reasoning and the
# anti-vacuity guards; what changed is where the two halves get their truth:
#
#  1. COMPLETENESS (metadata vs artifacts). Every package the WORKSPACE
#     declares for a platform must be present among that platform's artifacts.
#     `main` derived the declared set by rendering the lane recipes; here it
#     comes from `pixi publish --dry-run --target-platform <p>`, which is the
#     same instrument that produced the publish set — so adding a package
#     cannot leave the gate behind, and a `skip:` that silently ate an output
#     shows up as a missing name rather than as a smaller green run.
#
#  2. CLOSURE (fresh solve). Every artifact is solved for, pinned to its exact
#     version AND build, in a THROWAWAY workspace against the real channel
#     under strict priority — so nothing is satisfied by a warm environment or
#     a lockfile lying around. A package whose own dependencies cannot be
#     resolved is a package we must not have published.
#
# The lane-detection half of the original is GONE: this tree has one lane. The
# emptiness guards are kept verbatim in spirit — a gate that can pass on
# nothing is not a gate, and that is a lesson from a real run.
#
#   pixi run -e packaging nu tools/check-closure.nu --artifacts dist --remote <url>

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

const REMOTE = "https://prefix.dev/jackm97/naga-labs-staging"
const PLATFORMS = ["linux-64" "win-64" "osx-arm64"]

def conda-index [pkg: string] {
  let raw = (^bsdtar -xOf $pkg "info-*.tar.zst" | ^bsdtar -xOf - "info/index.json")
  $raw | from json
}

# What the workspace SAYS it ships for a platform, from the dry run.
def declared-names [platform: string] {
  let r = (^pixi publish --dry-run --target-platform $platform --to ./local-channel | complete)
  if $r.exit_code != 0 {
    print $r.stderr
    error make {msg: $"closure: the dry run for ($platform) failed — cannot determine the declared set"}
  }
  $r.stderr | lines | where {|l| $l starts-with "  - " }
    | each {|l| $l | parse -r '^  - (?P<n>\S+) v' | get n.0? } | compact | uniq | sort
}

def solve-one [platform: string, remote: string, name: string, version: string, build: string] {
  let dir = (mktemp -d)
  $'[workspace]
name = "closure"
channels = ["($remote)", "conda-forge"]
platforms = ["($platform)"]
channel-priority = "strict"

[dependencies]
"($name)" = { version = "==($version)", build = "($build)" }
' | save -f ($dir | path join "pixi.toml")
  let res = (do { cd $dir; ^pixi lock --no-progress } | complete)
  let ok = ($res.exit_code == 0)
  if not $ok {
    print $"[FAIL] closure: ($name) ($version) ($build) on ($platform) is UNSOLVABLE"
    print ($res.stderr | lines | last 12 | str join "\n")
  }
  rm -rf $dir
  $ok
}

def main [
  --artifacts: string = "dist"   # directory of platform subdirectories of .conda files
  --remote: string = $REMOTE
  --skip-solve                   # completeness only (for a platform whose channel upload is still in flight)
] {
  let found = (glob-native $"($artifacts | str replace --all '\' '/')/**/*.conda")
  if ($found | is-empty) {
    error make {msg: $"closure: no artifacts under ($artifacts) — refusing to pass vacuously"}
  }

  # SUBDIR COMES FROM THE ARTIFACT, never from the directory layout: a verify
  # job downloads three platforms' uploads and may flatten them.
  let staged = ($found | each {|p|
    let i = (conda-index $p)
    {path: $p, name: $i.name, version: $i.version, build: $i.build, subdir: $i.subdir}
  })
  let platforms = ($staged | get subdir | uniq | where {|s| $s != "noarch" } | sort)
  print $"closure: ($staged | length) artifacts across ($platforms | str join ', ')"
  if ($platforms | is-empty) {
    error make {msg: "closure: no platform artifacts — an empty set must never pass"}
  }

  mut results = []

  # ── 1. completeness ──────────────────────────────────────────────────────
  for p in $platforms {
    if $p not-in $PLATFORMS {
      error make {msg: $"closure: artifacts claim subdir ($p), which this workspace does not build"}
    }
    let declared = (declared-names $p)
    # ⚠ `noarch/` COUNTS TOWARDS A PLATFORM'S DECLARED SET. A platform job's
    # declared names include the `noarch: generic` packages it produces —
    # acpp-compiler-rt_linux-64 and acpp-compiler-rt21_linux-64 are declared by
    # the linux job and land in `noarch/`, because that is where a noarch
    # package goes whoever built it. Filtering on `subdir == p` alone therefore
    # reported them missing from a channel they were demonstrably on: run
    # 34124086049 SOLVED both of them in its own closure check, one section
    # below, while the completeness check above it called them absent.
    #
    # This cannot mask a real miss: the noarch names are platform-specific
    # (`…_linux-64` vs `…_win-64`), so a name declared by one platform is never
    # satisfied by another platform's artifact.
    let present = ($staged | where {|a| $a.subdir == $p or $a.subdir == "noarch" } | get name | uniq | sort)
    let missing = ($declared | where {|d| $d not-in $present })
    let ok = ($missing | is-empty)
    let noarch_n = ($staged | where {|a| $a.subdir == "noarch" } | get name | uniq | length)
    print $"[(if $ok { 'PASS' } else { 'FAIL' })] completeness ($p): ($present | length) of ($declared | length) declared packages present \(looked in ($p)/ and noarch/, the latter holding ($noarch_n) name\(s\))"
    if not $ok { print $"    MISSING: ($missing | str join ', ')" }
    $results = ($results | append $ok)
  }

  # ── 2. closure ───────────────────────────────────────────────────────────
  if $skip_solve {
    print "closure: --skip-solve given, the solve half did NOT run (completeness only)"
  } else {
    for a in $staged {
      let targets = (if $a.subdir == "noarch" { $platforms } else { [$a.subdir] })
      for t in $targets {
        let ok = (solve-one $t $remote $a.name $a.version $a.build)
        if $ok { print $"[PASS] closure: ($a.name) ($a.version) ($a.build) on ($t)" }
        $results = ($results | append $ok)
      }
    }
  }

  let failed = ($results | where {|r| not $r } | length)
  print $"closure: ($results | length) checks run, ($failed) failed"
  if $failed > 0 {
    error make {msg: $"closure gate: ($failed) of ($results | length) checks FAILED"}
  }
  print $"closure gate: all ($results | length) checks pass"
}