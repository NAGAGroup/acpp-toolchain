#!/usr/bin/env nu
# Static check: no pin_compatible() inside an output that inherits a staging
# build.
#
#   nu shared/check-pins.nu
#
# WHY THIS EXISTS: pin_compatible resolves against the output's own host/build
# environment, and an output with `inherit:` does not get one — the staging
# environment is what exists. Such a pin fails at BUILD time with
#
#   Could not apply pin_compatible. The following package is not part of the
#   solution: <name>
#
# which cost a full dispatch on both platform runners (run 31346371052). It is
# invisible to `--render-only`, because rendering does not resolve
# environments, so nothing else in the local gate set can catch it.
#
# The correct alternatives, both used in these recipes:
#   * let the dependency's own run_export carry the spec (declare it in the
#     STAGING host — the mutex reaches every inheriting output that way);
#   * or spell the range from context variables, still derived from one place.
#
# Non-inheriting outputs (the backend metapackages) may use pin_compatible
# freely, and do — that is where derived floors belong.

const RECIPES = ["release/recipe.yaml" "nightly/recipe.yaml" "naga/recipe.yaml"]

def check-recipe [path: string] {
  let lines = (open --raw $path | lines)
  mut current = "<top>"
  mut inherits = false
  mut bad = []

  for l in $lines {
    # A new output resets the state machine.
    if ($l | str starts-with "  - package:") or ($l | str starts-with "  - staging:") {
      $current = "<pending>"
      $inherits = false
      continue
    }
    if ($l | str starts-with "      name: ") {
      $current = ($l | str replace "      name: " "" | str trim)
      continue
    }
    if ($l | str starts-with "    inherit:") {
      $inherits = true
      continue
    }
    # Comments mentioning pin_compatible are fine; only real specs count.
    let t = ($l | str trim)
    if ($t | str starts-with "#") { continue }
    if ($inherits and ($t | str contains "pin_compatible")) {
      $bad = ($bad | append $"($path): output '($current)' inherits a staging build but uses pin_compatible — ($t)")
    }
  }
  $bad
}

# The mutex host spec must name THIS lane's own major.
#
# A bare `acpp-llvm` resolves to the HIGHEST published major, which would pin
# the release lane to the nightly lane's range — it builds green, publishes
# green, and produces a channel where the release toolchain demands the wrong
# lane. Checked on the RENDERED recipe rather than the source text, because the
# spec is built from a context variable and the thing that matters is what the
# variable expanded to.
def check-mutex-spec [recipe: string, platform: string] {
  let variants = ([shared variants $"($platform).yaml"] | path join)
  let res = (do {
    (^rattler-build build --recipe $recipe --experimental --render-only
      -m $variants --target-platform $platform)
  } | complete)
  if $res.exit_code != 0 {
    return [$"($recipe) [($platform)]: render failed, cannot check the mutex spec"]
  }
  let rendered = ($res.stdout | from json)
  # The mutex lives on the STAGING output, which the render exposes under
  # `staging_caches`, NOT under each output's own `requirements` (an
  # inheriting output has none of its own — that is the whole reason the mutex
  # moved there).
  let specs = ($rendered
    | each {|o| $o.recipe.staging_caches? | default [] }
    | flatten
    | each {|c| $c.requirements?.host? | default [] }
    | flatten
    | each {|s| if ($s | describe) == "string" { $s } else { "" } }
    | where {|s| $s | str starts-with "acpp-llvm" }
    | uniq)

  if ($specs | is-empty) {
    return [$"($recipe) [($platform)]: NO acpp-llvm host spec in the rendered recipe — the lane mutex would not be applied at all"]
  }
  let bare = ($specs | where {|s| ($s | str trim) == "acpp-llvm" })
  if ($bare | is-not-empty) {
    return [$"($recipe) [($platform)]: BARE acpp-llvm host spec — resolves to the highest published major, not this lane's"]
  }
  # Must be pinned to an exact bare major, e.g. "acpp-llvm ==21".
  let ok = ($specs | all {|s| $s =~ '^acpp-llvm ==[0-9]+$' })
  if not $ok {
    return [$"($recipe) [($platform)]: mutex host spec is not an exact major pin — got ($specs | str join ', ')"]
  }
  print $"check-pins: ($recipe) [($platform)] mutex host spec = ($specs | uniq | str join ', ')"
  []
}

def main [] {
  mut bad = []
  for r in $RECIPES {
    if ($r | path exists) { $bad = ($bad | append (check-recipe $r)) }
  }
  for r in $RECIPES {
    if not ($r | path exists) { continue }
    for p in ["linux-64" "win-64"] {
      $bad = ($bad | append (check-mutex-spec $r $p))
    }
  }
  if ($bad | is-empty) {
    print "check-pins: no pin_compatible in staging-inheriting outputs"
  } else {
    for b in $bad { print $"[FAIL] ($b)" }
    error make {msg: $"check-pins: ($bad | length) unusable pin_compatible call\(s\) — these fail at build time, not render time"}
  }
}
