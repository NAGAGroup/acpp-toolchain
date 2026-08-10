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

const RECIPES = ["release/recipe.yaml" "nightly/recipe.yaml"]

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

def main [] {
  mut bad = []
  for r in $RECIPES {
    if ($r | path exists) { $bad = ($bad | append (check-recipe $r)) }
  }
  if ($bad | is-empty) {
    print "check-pins: no pin_compatible in staging-inheriting outputs"
  } else {
    for b in $bad { print $"[FAIL] ($b)" }
    error make {msg: $"check-pins: ($bad | length) unusable pin_compatible call\(s\) — these fail at build time, not render time"}
  }
}
