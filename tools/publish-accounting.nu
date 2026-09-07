# publish-accounting.nu — read a `pixi publish` log and assert the run built
# what it was supposed to build.
#
# WHY THE PUBLISH'S OWN EXIT CODE IS NOT ENOUGH. A whole-workspace publish
# prints one line per package it BUILT and one per package it SKIPPED, and a
# skip is legitimate — `acpp-bolt` on Windows, `acpp-libcxx` off macOS, the two
# activation ports for the other platforms. It is also exactly what a broken
# `skip:` expression produces. Exit code 0 means "nothing errored", not "the
# expected set was produced": a recipe that silently skipped every output would
# publish nothing and pass.
#
# So this asserts the SET: built + skipped == the number of package directories
# in the workspace, and built > 0. Both numbers are printed, so the log always
# says what was checked rather than only that it passed.
#
# NON-VACUOUS BY CONSTRUCTION: a log it cannot parse produces zero of both, and
# zero built fails before any comparison can be called a pass.
#
#   pixi run -e packaging nu tools/publish-accounting.nu --log publish.log --expect 49

def main [
  --log: string     # the captured publish output (stdout and stderr together)
  --expect: int     # how many package directories the workspace holds
] {
  if ($log | is-empty) { error make {msg: "publish-accounting: --log <file> is required"} }
  if not ($log | path exists) { error make {msg: $"publish-accounting: ($log) does not exist"} }
  if ($expect == null) or ($expect < 1) {
    error make {msg: "publish-accounting: --expect <n> is required and must be at least 1"}
  }

  let lines = (open --raw $log | lines)

  # A built package: the build-list line pixi prints per package.
  let built = ($lines
    | each {|l| $l | parse -r '^\s*- (?P<name>\S+) v(?P<version>\S+) \[(?P<build>[^\]]+)\]' }
    | flatten)
  # A skipped one: pixi names the DIRECTORY, not the package.
  let skipped = ($lines
    | each {|l| $l | parse -r "skipping '(?P<dir>[^']+)': no outputs for platform" }
    | flatten)

  # DISCRIMINATE A SKIP FROM A FAILURE. Both leave a package unbuilt, and only
  # one of them is fine. The phrases below are pixi's own; anything matching
  # them that is NOT the skip line above is a real error we must not swallow.
  #
  # ⚠ ONE REGEX, ON ONE LINE, AND THAT SHAPE IS DELIBERATE. A multi-line
  # boolean chain does not survive nushell 0.114 either way round: a line
  # BEGINNING with `or` parses as a command named `or`, and a line ENDING with
  # `or` is an "incomplete math expression". Both fail at RUN time, inside a
  # closure, where `nu -c 'source <file>'` never reaches them — the second
  # member of the "a parse check cannot see this" family, after the
  # interpolation that called `exit`. Found by exercising this guard's failure
  # path, which is exactly why a guard that has never fired is untested code.
  let errors = ($lines | where {|l| $l =~ '(?i)not part of the publish set|cannot be published on its own|^error|failed to build' })

  let names = ($built | get name | uniq)
  print $"publish-accounting: ($built | length) builds over ($names | length) names, ($skipped | length) skipped, expecting ($expect) package directories"
  if not ($skipped | is-empty) {
    print $"publish-accounting: skipped — ($skipped | get dir | each {|d| $d | path basename } | str join ', ')"
  }

  mut failures = []
  if ($built | is-empty) {
    $failures = ($failures | append "zero packages were built — either the log is not a publish log or every output was skipped")
  }
  # Two builds of one name (the with_cfg rows) count ONCE against the package
  # directory total, because a directory is what pixi skips or builds.
  let accounted = (($names | length) + ($skipped | length))
  if $accounted != $expect {
    $failures = ($failures | append $"($names | length) built + ($skipped | length) skipped = ($accounted), but the workspace holds ($expect) package directories — ($expect - $accounted) unaccounted for")
  }
  if not ($errors | is-empty) {
    for e in ($errors | first 10) { print $"  publish error line: ($e | str trim)" }
    $failures = ($failures | append $"($errors | length) error line\(s\) in the publish log")
  }

  if not ($failures | is-empty) {
    for f in $failures { print $"FAIL ($f)" }
    error make {msg: $"publish-accounting: ($failures | length) failure\(s\) — see above"}
  }
  print $"publish-accounting: OK — every one of ($expect) package directories is accounted for"
}
