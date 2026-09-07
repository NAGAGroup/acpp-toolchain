# check-source-paths.nu — every `path:` source in every recipe must exist,
# relative to the recipe that names it.
#
# TWO RULES THAT LOOK THE SAME AND ARE NOT, which is the whole reason this
# exists:
#
#   * a `path:` SOURCE resolves against the RECIPE directory. `..` works there,
#     and `_acpp-stage` has always relied on it.
#   * `license_file` resolves against the rendered SOURCE directory. `..` never
#     works there, measured both ways.
#
# The licence sweep in 89f0257 applied the second rule to a line governed by the
# first: it rewrote `_acpp-llvm-spirv-stage`'s vendored-licence SOURCE from
# `../_shared/licenses/SPIRV-LLVM-Translator-LICENSE.TXT` to
# `licenses/SPIRV-LLVM-Translator-LICENSE.TXT`, and run 34109157780 failed at
# FETCH time with "failed to canonicalize path". The sweep's own verification
# could not see it, because it only inspected `license_file:` lines — it
# checked the rule it had in mind rather than the file it had changed.
#
# So this asserts the property directly, on every path source in the tree, and
# it fires on a laptop at render time instead of on a runner at fetch time. It
# also covers the ROCm tarball and the stage's other path sources, which no
# other check looks at.
#
#   pixi run -e packaging nu tools/check-source-paths.nu

def main [] {
  let recipes = (glob "packages/**/recipe.yaml")
  if ($recipes | length) < 20 {
    error make {msg: $"check-source-paths: only ($recipes | length) recipes found — that is a broken glob, and a check over nothing is not a check"}
  }

  mut checked = 0
  mut missing = []
  for r in $recipes {
    let dir = ($r | path dirname)
    # `- path: <x>` under a source list. url: sources are fetched, not local, so
    # they are not this check's business.
    let paths = (open --raw $r | lines
      | each {|l| $l | parse -r '^\s*-?\s*path:\s*(?P<p>\S+)\s*$' }
      | flatten | get p)
    for p in $paths {
      # An absolute path is left alone: nothing in this tree uses one, and a
      # check that silently rewrote one would be worse than the defect.
      let full = (if ($p | str starts-with "/") { $p } else { $dir | path join $p | path expand })
      $checked = $checked + 1
      if not ($full | path exists) {
        $missing = ($missing | append $"($r | path relative-to (pwd)) names a path source that does not exist: ($p) -> ($full)")
      }
    }
  }

  print $"check-source-paths: ($checked) path source\(s\) across ($recipes | length) recipes"
  if $checked < 10 {
    error make {msg: $"check-source-paths: only ($checked) path sources found — this tree is built out of them, so that is a broken scan"}
  }
  if not ($missing | is-empty) {
    for m in $missing { print $"MISSING ($m)" }
    error make {msg: $"check-source-paths: ($missing | length) path source\(s\) do not exist — each one fails at FETCH time on a runner"}
  }
  print "check-source-paths: OK — every path source resolves from its own recipe directory"
}
