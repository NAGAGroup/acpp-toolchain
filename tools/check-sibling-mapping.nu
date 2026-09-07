# check-sibling-mapping.nu — every workspace sibling a RECIPE names must be
# MAPPED in that package's `[package.build-dependencies]`.
#
# THE DEFECT THIS EXISTS FOR, and why no existing check could see it. A recipe
# names its dependencies as if they came from a channel — that is the design:
# the manifest table is a source-path MAPPING and the recipe is the sole
# authority for what a dependency IS. But the mapping is what tells pixi that
# the name is a SIBLING TO BUILD rather than a package to fetch. Omit it and
# pixi resolves that requirement against channels only; if the name has never
# been published, the build dies at its first host solve with
# "No candidates were found for <name>".
#
# `pixi publish --dry-run` CANNOT CATCH THIS. It enumerates the set, renders
# every recipe and prints the build order — but it does NOT solve host
# environments. That is why a workspace can render 42 / 35 / 40 green on a
# laptop and die on the first solve on a runner, which is exactly what happened
# to `acpp` (run 34096769046): its recipe carried `acpp-runtime ==<version>`
# under host, its manifest deliberately omitted the mapping under a rule that
# had already dissolved, and nothing local disagreed.
#
# So this closes the gap in the instrument rather than the one crash site:
# the property is "every sibling named is a sibling mapped", asserted over the
# whole workspace, on every platform.
#
#   pixi run -e packaging nu tools/check-sibling-mapping.nu
#   pixi run -e packaging nu tools/check-sibling-mapping.nu --platform win-64

const PLATFORMS = ["linux-64" "win-64" "osx-arm64"]

# A dependency spec as it appears in a rendered requirement list, reduced to the
# package NAME: `acpp-clang-21[version="==21.1.8",build="llvm21_1_8_*"]` and
# `acpp-runtime ==2026.09.07` and a bare `nushell` all reduce to their name.
def spec-name [spec: string] {
  $spec | split row "[" | first | split row " " | first | str trim
}

def render [dir: string, platform: string] {
  let recipe = ($dir | path join "recipe.yaml")
  if not ($recipe | path exists) { return null }
  let r = (^pixi run -e dev rattler-build build --render-only --recipe $recipe -m variants.yaml --target-platform $platform | complete)
  if $r.exit_code != 0 { return null }   # a platform-skipped package renders empty
  # `complete` is for external commands only, so a parse failure is caught with
  # try/catch rather than by inspecting an exit code.
  try { $r.stdout | from json } catch { null }
}

def main [--platform: string] {
  let platforms = (if ($platform | is-empty) { $PLATFORMS } else { [$platform] })

  let dirs = (ls packages | where type == dir | get name
    | where {|p| ($p | path join "pixi.toml" | path exists) })
  print $"check-sibling-mapping: ($dirs | length) package directories over ($platforms | str join ', ')"

  # ── 1. WHO PRODUCES WHAT. The workspace key is the manifest's [package] name,
  # which for a `${{ target_platform }}`-templated recipe is NOT the package
  # name it emits — acpp-clang-impl emits acpp-clang_impl_linux-64. Built by
  # rendering, never by guessing at the template.
  mut owner = {}          # emitted package name -> workspace key
  mut renders = {}        # "dir|platform" -> rendered outputs
  for d in $dirs {
    let key = (open ($d | path join "pixi.toml") | get package.name)
    for p in $platforms {
      let out = (render $d $p)
      if $out == null { continue }
      $renders = ($renders | insert $"($d)|($p)" $out)
      for o in $out {
        # `upsert`, not `insert`: acpp-clang and acpp-clangxx each render TWICE
        # per platform (the with_cfg rows), and a name is produced by exactly
        # one directory, so re-recording the same owner is expected.
        $owner = ($owner | upsert $o.recipe.package.name $key)
      }
    }
  }
  print $"check-sibling-mapping: ($owner | columns | length) package names produced by the workspace"
  if ($owner | columns | length) < 20 {
    error make {msg: $"check-sibling-mapping: only ($owner | columns | length) names rendered — that is a broken render, not a small workspace, and a comparison against it would pass vacuously"}
  }

  # ── 2. EVERY SIBLING NAMED MUST BE MAPPED.
  mut failures = []
  mut checked = 0
  for d in $dirs {
    let manifest = (open ($d | path join "pixi.toml"))
    let mapped = ($manifest | get -o package.build-dependencies | default {} | columns)
    let self_key = ($manifest | get package.name)
    for p in $platforms {
      let out = ($renders | get -o $"($d)|($p)")
      if $out == null { continue }
      for o in $out {
        let reqs = ($o.recipe.requirements)
        # build / host / run only. run_exports are NOT resolved at build time —
        # they are strings handed to a CONSUMER — so a sibling named only there
        # needs no mapping.
        let specs = ([
          ($reqs | get -o build | default []),
          ($reqs | get -o host | default []),
          ($reqs | get -o run | default [])
        ] | flatten | where {|s| ($s | describe) == "string" })
        for s in $specs {
          let name = (spec-name $s)
          let key = ($owner | get -o $name)
          if $key == null { continue }          # a conda-forge package, not ours
          if $key == $self_key { continue }     # its own other output
          $checked = $checked + 1
          if $key not-in $mapped {
            $failures = ($failures | append $"($d | path basename) [($p)] names sibling ($name), produced by ($key), which its pixi.toml does not map in [package.build-dependencies]")
          }
        }
      }
    }
  }

  print $"check-sibling-mapping: ($checked) sibling reference\(s\) checked"
  if $checked < 20 {
    error make {msg: $"check-sibling-mapping: only ($checked) sibling references found — this workspace is built out of siblings, so that is a broken scan rather than a pass"}
  }
  if not ($failures | is-empty) {
    for f in ($failures | uniq) { print $"FAIL ($f)" }
    error make {msg: $"check-sibling-mapping: ($failures | uniq | length) unmapped sibling reference\(s\) — each one dies at its first host solve with 'No candidates were found'"}
  }
  print "check-sibling-mapping: OK — every sibling a recipe names is mapped in its manifest"
}
