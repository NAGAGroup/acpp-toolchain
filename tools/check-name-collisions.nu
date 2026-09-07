# check-name-collisions.nu — assert that no package NAME is produced at more
# than one VERSION on a platform.
#
# ⚠ THE ASSERTION IS NOT "EVERY NAME IS UNIQUE", AND WRITING IT THAT WAY WOULD
# MAKE THE GATE RED ON A CORRECT TREE. `acpp-clang` and `acpp-clangxx` are each
# built TWICE on every platform — once per `with_cfg` row — and that is
# upstream's design: the cfg build carries the conda configuration files that
# make clang prefix-aware, the nocfg build is a vanilla clang for tooling, and
# `acpp-clang-no-conda-cfg` exists solely to select the second. Two builds of
# one name at one version, distinguished by build string, is a variant. Two
# VERSIONS of one name is a real collision: two recipes both claiming to
# produce it, which is how a set ends up publishing whichever built last.
#
# It also reports names built more than once so the with_cfg pairs stay
# VISIBLE — a third build of a name at one version is not an error but is worth
# seeing, and a silently growing variant matrix is how build times double.
#
# `--log` reads a publish run that already happened instead of rendering a new
# one. In CI the real publish has just printed the set, and re-deriving it costs
# minutes and can disagree with what was actually uploaded — the log is the
# stronger evidence, not merely the cheaper one.
#
#   pixi run -e packaging nu tools/check-name-collisions.nu --platform linux-64
#   pixi run -e packaging nu tools/check-name-collisions.nu --platform linux-64 --log publish.log

def main [--platform: string, --log: string] {
  if ($platform | is-empty) {
    error make {msg: "check-name-collisions: --platform <p> is required"}
  }

  let text = (if ($log | is-empty) {
    let r = (^pixi publish --dry-run --target-platform $platform --to ./local-channel | complete)
    if $r.exit_code != 0 {
      print $r.stderr
      error make {msg: $"check-name-collisions: the dry run for ($platform) failed"}
    }
    $r.stderr
  } else {
    if not ($log | path exists) { error make {msg: $"check-name-collisions: ($log) does not exist"} }
    open --raw $log
  })

  # The build list goes to STDERR, one `  - <name> v<version> [<build>]` line
  # per BUILD (not per name).
  let builds = ($text | lines
    | each {|l| $l | parse -r '^\s*- (?P<name>\S+) v(?P<version>\S+) \[(?P<build>[^\]]+)\]' }
    | flatten)

  if ($builds | is-empty) {
    error make {msg: $"check-name-collisions: parsed zero builds out of the dry run for ($platform) — the output format changed, and a pass over nothing is not a pass"}
  }

  let by_name = ($builds | group-by name)
  mut failures = []
  mut multi = []
  for name in ($by_name | columns) {
    let rows = ($by_name | get $name)
    let versions = ($rows | get version | uniq)
    if ($versions | length) > 1 {
      $failures = ($failures | append $"($name) is produced at ($versions | length) versions: ($versions | str join ', ')")
    }
    if ($rows | length) > 1 {
      $multi = ($multi | append $"($name) x($rows | length) at v($versions | first) \(builds: ($rows | get build | str join ', '))")
    }
  }

  print $"check-name-collisions: ($platform) — ($builds | length) builds, ($by_name | columns | length) distinct names"
  for m in $multi { print $"  multiple builds of one name, expected for with_cfg: ($m)" }
  if not ($failures | is-empty) {
    for f in $failures { print $"FAIL ($f)" }
    error make {msg: $"check-name-collisions: ($failures | length) name\(s\) produced at more than one version"}
  }
  print "check-name-collisions: OK — every name has exactly one version"
}
