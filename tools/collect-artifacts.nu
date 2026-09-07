# collect-artifacts.nu — gather the .conda files a publish produced, BY
# PUBLISHED NAME.
#
# ⚠ NEVER GLOB THE BUILD DIRECTORY. `.pixi/bld` holds whatever previous runs
# left there, including artifacts from another build number and — the expensive
# mistake — `_acpp-stage`, whose payload is the ENTIRE toolchain under
# `_stage/`. A gate fed by a glob would compare the stage against every slicer
# and either drown in false positives or, worse, quietly gate a set that is not
# the set that was published.
#
# So the input is the PUBLISH LOG: every `- <name> v<version> [<build>]` line
# it printed is a package that must exist as a file, and a name it cannot find
# is a hard failure rather than a smaller set. The output directory is what the
# gates read.
#
#   pixi run -e packaging nu tools/collect-artifacts.nu --log publish.log --into dist/linux-64

def main [
  --log: string        # the captured publish output
  --into: string       # destination directory
  --search: string = "." # where to look for the built artifacts
] {
  if ($log | is-empty) { error make {msg: "collect-artifacts: --log <file> is required"} }
  if ($into | is-empty) { error make {msg: "collect-artifacts: --into <dir> is required"} }
  if not ($log | path exists) { error make {msg: $"collect-artifacts: ($log) does not exist"} }

  let built = (open --raw $log | lines
    | each {|l| $l | parse -r '^\s*- (?P<name>\S+) v(?P<version>\S+) \[(?P<build>[^\]]+)\]' }
    | flatten | uniq)
  if ($built | is-empty) {
    error make {msg: "collect-artifacts: the log names no built packages — refusing to collect an empty set"}
  }

  mkdir $into
  # One listing of the tree, reused for every lookup: the build directory holds
  # tens of thousands of files and a glob per package would walk it each time.
  let candidates = (glob $"($search)/**/*.conda" | where {|f| not ($f | str contains $into) })
  print $"collect-artifacts: ($built | length) published package\(s\), ($candidates | length) .conda file\(s\) on disk"

  mut missing = []
  mut copied = 0
  for b in $built {
    let want = $"($b.name)-($b.version)-($b.build).conda"
    let hit = ($candidates | where {|f| ($f | path basename) == $want })
    if ($hit | is-empty) {
      $missing = ($missing | append $want)
      continue
    }
    cp ($hit | first) ($into | path join $want)
    $copied = $copied + 1
  }

  if not ($missing | is-empty) {
    for m in $missing { print $"MISSING ($m)" }
    error make {msg: $"collect-artifacts: ($missing | length) published package\(s\) have no artifact on disk — the gates would have run over an incomplete set"}
  }
  print $"collect-artifacts: OK — collected ($copied) artifact\(s\) into ($into)"
}
