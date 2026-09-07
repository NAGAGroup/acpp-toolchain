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
  # FOLLOW THE REDIRECT pixi follows. A thin per-platform manifest carries no
  # recipe of its own: `package.build.config.recipe` points at the family's
  # shared one. Looking only for `<dir>/recipe.yaml` made this gate skip
  # exactly the ten packages the manifest-name rule exists for — caught by the
  # render-coverage guard below, which is the point of having it.
  let manifest = (open ($dir | path join "pixi.toml"))
  let redirect = ($manifest | get -o package.build.config.recipe)
  let recipe = (if $redirect == null {
    $dir | path join "recipe.yaml"
  } else {
    $dir | path join $redirect | path expand
  })
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

  # ── 1. WHO PRODUCES WHAT.
  #
  # ⚠ THE MAP IS emitted name -> MANIFEST name, and the two being DIFFERENT is
  # itself the defect this gate now catches. PIXI MATCHES A SOURCE PACKAGE BY
  # ITS MANIFEST `[package] name`, never by rendering the recipe — proved on a
  # two-package throwaway workspace, and the reason run 34097701602 died three
  # levels down a solve on `acpp-clang_impl_linux-64` while that very name sat
  # in the build list. An earlier version of this gate accepted a manifest name
  # that merely OWNED the emitted name: it modelled what we wanted pixi to do
  # rather than what it does, and it passed on the tree that then failed in CI.
  mut owner = {}          # emitted package name -> manifest name of its package
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

  # ⚠ A FAILED RENDER IS INDISTINGUISHABLE FROM A PLATFORM SKIP, and both leave
  # a package unexamined — so a broken environment would make this gate pass by
  # checking almost nothing. Measured: a scratch copy whose `dev` environment
  # was not installed rendered a third of the workspace and reported OK.
  # A package that renders on NO platform is therefore a hard failure: a real
  # skip is per-platform, never everywhere.
  # `$renders` is mutable, and a closure cannot capture a mutable binding in
  # nushell — so it is frozen into an immutable copy first. (A parse-time
  # error, caught here rather than at 3am in CI.)
  let rendered_keys = ($renders | columns)
  let never_rendered = ($dirs | where {|d| $platforms | all {|p| $"($d)|($p)" not-in $rendered_keys } })
  if not ($never_rendered | is-empty) {
    for d in $never_rendered { print $"NO RENDER ($d) on any of ($platforms | str join ', ')" }
    error make {msg: $"check-sibling-mapping: ($never_rendered | length) package\(s\) rendered on NO platform — the scan would have skipped them silently"}
  }

  # ── 1b. WHICH OF OUR PACKAGES IS SOMEONE ELSE'S HOST (or build) DEPENDENCY.
  # Those are the ones whose own RUN dependencies get solved during a build,
  # because a host dependency drags its run dependencies into the environment.
  # ⚠ IT IS A CLOSURE, NOT A MEMBERSHIP TEST, and the difference is the whole
  # failure of run 34097701602. That solve reached `acpp-clang_impl_linux-64`
  # THREE levels down: the activation host-depends on `acpp`, whose RUN
  # dependency is `acpp-clang`, whose RUN dependency is the impl package. A
  # host dependency drags its run dependencies, and those drag theirs. So the
  # solve-relevant set starts at every direct build/host dependency and then
  # absorbs the run dependencies of everything already in it, to a fixpoint.
  #
  # An earlier version tested only direct membership and stayed GREEN on the
  # exact tree that had just failed in CI — which is why this is spelled out
  # rather than left as a one-liner.
  mut reqs_by_name = {}
  for k in ($renders | columns) {
    for o in ($renders | get $k) {
      let r = $o.recipe.requirements
      let deps = {
        hb: ([($r | get -o build | default []), ($r | get -o host | default [])]
          | flatten | where {|s| ($s | describe) == "string" } | each {|s| spec-name $s }),
        run: ($r | get -o run | default [] | where {|s| ($s | describe) == "string" } | each {|s| spec-name $s }),
      }
      $reqs_by_name = ($reqs_by_name | upsert $o.recipe.package.name $deps)
    }
  }
  let all_reqs = $reqs_by_name
  mut relevant = ($all_reqs | values | get hb | flatten | uniq)
  mut grew = true
  while $grew {
    let before = ($relevant | length)
    let more = ($relevant | each {|n| $all_reqs | get -o $n | default {run: []} | get run } | flatten)
    $relevant = ($relevant | append $more | uniq)
    $grew = (($relevant | length) > $before)
  }
  let host_depended = $relevant
  print $"check-sibling-mapping: ($host_depended | length) names are solve-relevant \(a build/host dependency, or reachable from one through run dependencies)"

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
        # BUILD and HOST are solved for THIS package, always.
        #
        # RUN is solved only when this package is itself pulled into someone
        # else's HOST environment — a host dependency drags its run
        # dependencies, which is exactly how run 34097701602 reached
        # `acpp-clang_impl_linux-64`: through `acpp` (host dep of the
        # activation) → acpp's run dep on `acpp-clang` → ITS run dep on the
        # impl package. Measured on the probe workspace: a run-only dependency
        # on a name no manifest carries builds fine in isolation, and the same
        # spec is fatal one level inside a host solve.
        #
        # So `acpp-toolkit`'s run dependencies on the multi-output activation
        # names are NOT a defect: nothing host-depends on the toolkit, and a
        # USER installing it resolves those names from the CHANNEL, where they
        # are published. `is_host_dep` below is what encodes that difference
        # instead of leaving it to whoever reads the failure.
        let self_names = ($out | each {|x| $x.recipe.package.name })
        let is_host_dep = ($self_names | any {|n| $n in $host_depended })
        let specs = ([
          ($reqs | get -o build | default []),
          ($reqs | get -o host | default []),
          (if $is_host_dep { $reqs | get -o run | default [] } else { [] })
        ] | flatten | where {|s| ($s | describe) == "string" })
        for s in $specs {
          let name = (spec-name $s)
          let key = ($owner | get -o $name)
          if $key == null { continue }          # a conda-forge package, not ours
          if $key == $self_key { continue }     # its own other output
          $checked = $checked + 1
          # (a) RESOLVABLE AT ALL. The spec names a package this workspace
          # produces, so it must be a name pixi can match a source package by —
          # which is a MANIFEST name. If the producing package's manifest is
          # called something else, no mapping anywhere can rescue the spec: it
          # falls through to the channels, where our packages have never been
          # published.
          if $key != $name {
            $failures = ($failures | append $"($d | path basename) [($p)] names ($name), which this workspace PRODUCES but only as an OUTPUT of the package whose manifest is called ($key). pixi matches source packages by MANIFEST name, so this spec can never resolve — the producing package needs a manifest per platform named for what it emits")
            continue
          }
          # (b) MAPPED. A name pixi could match still has to be declared a
          # sibling, or it is looked for in channels instead of built.
          if $name not-in $mapped {
            $failures = ($failures | append $"($d | path basename) [($p)] names sibling ($name), which its pixi.toml does not map in [package.build-dependencies]")
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
