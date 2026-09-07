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

  # ── NO TWO SOURCES MAY TARGET THE SAME DIRECTORY ─────────────────────────
  # rattler copies each source into the work dir and REFUSES to overwrite what
  # an earlier one placed: "File already exists". Two sources with the same
  # target_directory is therefore always fatal, whatever they contain.
  #
  # This is the other half of the assertion that missed run 11's defect. The
  # licence sweep's "append if a source block exists" branch appended the
  # licence source to recipes that ALREADY had exactly it, and the check I
  # wrote afterwards asked "does anything name licenses/ WITHOUT a source" —
  # never "does anything have TWO". Same lesson one sweep later: assert the
  # change you MADE, on the files you TOUCHED, not the rule you had in mind.
  mut dupes = []
  for r in $recipes {
    # Pair each `- path:` with the `target_directory:` that follows it, which
    # is how the YAML reads: a target belongs to the source above it.
    mut pairs = []
    mut current = ""
    for l in (open --raw $r | lines) {
      let p = ($l | parse -r '^\s*-\s*path:\s*(?P<v>\S+)\s*$' | get v.0?)
      if $p != null { $current = $p; continue }
      let t = ($l | parse -r '^\s*target_directory:\s*(?P<v>\S+)\s*$' | get v.0?)
      if $t != null and $current != "" { $pairs = ($pairs | append {path: $current, target: $t}); $current = "" }
    }
    let collisions = ($pairs | group-by target | transpose target rows
      | where {|g| ($g.rows | length) > 1 })
    for c in $collisions {
      $dupes = ($dupes | append $"($r | path relative-to (pwd)) has ($c.rows | length) sources targeting '($c.target)': ($c.rows | get path | str join ', ')")
    }
  }
  if not ($dupes | is-empty) {
    for d in $dupes { print $"DUPLICATE ($d)" }
    error make {msg: $"check-source-paths: ($dupes | length) recipe\(s\) have two sources targeting one directory — rattler refuses the second with \"File already exists\""}
  }

  print $"check-source-paths: ($checked) path source\(s\) across ($recipes | length) recipes, no two targeting one directory"
  if $checked < 10 {
    error make {msg: $"check-source-paths: only ($checked) path sources found — this tree is built out of them, so that is a broken scan"}
  }
  if not ($missing | is-empty) {
    for m in $missing { print $"MISSING ($m)" }
    error make {msg: $"check-source-paths: ($missing | length) path source\(s\) do not exist — each one fails at FETCH time on a runner"}
  }
  print "check-source-paths: OK — every path source resolves from its own recipe directory"
}
