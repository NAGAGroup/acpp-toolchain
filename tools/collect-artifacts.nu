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
  if $no_dir { glob $p --no-dir } else { glob $p }
}

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
  let candidates = (glob-native $"($search)/**/*.conda" | where {|f| not ($f | str contains $into) })
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