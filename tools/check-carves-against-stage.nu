# check-carves-against-stage.nu — resolve every package's slice against the
# REAL stage listing, and name every path two packages both claim.
#
# THE GAP THIS CLOSES. Three reds in a row were one defect: a slice and the
# stage disagreeing about where a file is, or two slices claiming the same file.
# Neither is visible locally, because nothing local has a built stage — the
# carves are checkable against upstream (tools/upstream-paths.nu) and the stage
# was checkable against nothing. So the stage now publishes the listing of what
# it installed, and this resolves the slices against it.
#
# It answers three questions that previously cost a runner cycle each:
#   * does every glob match something in the real stage? (runs 9, 13, 14)
#   * do two packages claim the same path? (run 17/18: acpp-libllvm21's
#     `lib*.so.<sover>` swallowed libclang-cpp.so.21.1, and because it is a HOST
#     dependency of the package that owns that file, the victim shipped EMPTY
#     while reporting a successful copy)
#   * is anything in the stage claimed by nobody?
#
# The listing comes from a run's artifacts:
#   gh run download <id> -R NAGAGroup/acpp-toolchain -n dist-linux-64 -D /tmp/x
#   pixi run -e packaging nu tools/check-carves-against-stage.nu --listing /tmp/x/_temp/stage-paths.txt
#
# It is ADVISORY about coverage and FATAL about collisions, because a collision
# is always a defect while an unclaimed path may be a deliberate omission.

const PLATFORM_OF = {"linux-64": "linux", "osx-arm64": "osx", "win-64": "win"}

# The listing is `path\ttype\ttarget\tresolves` since the stage learned to
# record types; older listings are bare paths. Accept both.
def read-listing [path: string] {
  open --raw $path | lines | where {|l| $l != "" } | each {|l| $l | split row "\t" | first }
}

# A carve glob is a package path. Turn it into a matcher over the listing:
# `**` crosses directories, `*` does not cross a `/`.
def glob-to-regex [g: string] {
  let escaped = ($g | str replace --all "." "\\." | str replace --all "+" "\\+")
  let with_globstar = ($escaped | str replace --all "**" "\u{1}")
  let with_star = ($with_globstar | str replace --all "*" "[^/]*")
  let final = ($with_star | str replace --all "\u{1}" ".*")
  $"^($final)$"
}

def main [--listing: string, --platform: string = "linux-64"] {
  if ($listing | is-empty) or (not ($listing | path exists)) {
    print $"check-carves-against-stage: no listing at '($listing)'"
    print "  Download one from a run's artifacts:"
    print "    gh run download <id> -R NAGAGroup/acpp-toolchain -n dist-<platform> -D /tmp/x"
    print "  This check is skipped without it — it is not a pass."
    return
  }
  let stage = (read-listing $listing)
  if ($stage | length) < 100 {
    error make {msg: $"check-carves-against-stage: the listing has only ($stage | length) entries — that is not a built LLVM stage"}
  }
  let sel = ($PLATFORM_OF | get $platform)
  print $"check-carves-against-stage: ($stage | length) stage paths, platform ($platform)"

  # Each package's claimed set, resolved from its RENDERED carve so that jinja
  # and platform selectors are the recipe's own, not this script's guess.
  mut claims = {}
  mut unmatched = []
  for d in (ls packages | where type == dir | get name) {
    let recipe = ($d | path join "recipe.yaml")
    if not ($recipe | path exists) { continue }
    let r = (^pixi run -e dev rattler-build build --render-only --recipe $recipe -m variants.yaml --target-platform $platform | complete)
    if $r.exit_code != 0 { continue }
    let outs = (try { $r.stdout | from json } catch { [] })
    for o in $outs {
      let name = $o.recipe.package.name
      let carve = ($o.recipe.build.script?.env?.ACPP_CARVE? | default "")
      if $carve == "" { continue }
      let globs = ($carve | split row ";" | each {|g| $g | str trim } | where {|g| $g != "" })
      # ⚠ EXCLUDES ARE PART OF THE SLICE, and a checker that ignores them
      # invents collisions: acpp-clang-21 includes the whole resource include
      # tree and EXCLUDES the five subdirectories that belong to
      # acpp-compiler-rt21, exactly as carve.nu computes `included - excluded`.
      # The first run of this tool reported 23 such pairs as defects — the
      # model was wrong, not the tree.
      let excl = ($o.recipe.build.script?.env?.ACPP_CARVE_EXCLUDE? | default "")
      let excl_globs = ($excl | split row ";" | each {|g| $g | str trim } | where {|g| $g != "" })
      mut excluded = []
      for g in $excl_globs {
        let rel = (if ($g | str starts-with "Library/") { $g | str substring 8.. } else { $g })
        let re = (glob-to-regex $rel)
        $excluded = ($excluded | append ($stage | where {|p| $p =~ $re }))
      }
      mut owned = []
      for g in $globs {
        # Windows globs are written with the Library/ layout prefix; the stage
        # listing is relative to the layout root, so strip it.
        let rel = (if ($g | str starts-with "Library/") { $g | str substring 8.. } else { $g })
        let re = (glob-to-regex $rel)
        let hits = ($stage | where {|p| $p =~ $re })
        if ($hits | is-empty) { $unmatched = ($unmatched | append $"($name): '($g)' matches nothing in the stage") }
        $owned = ($owned | append $hits)
      }
      # included MINUS excluded, which is what carve.nu ships.
      $claims = ($claims | upsert $name ($owned | uniq | where {|p| $p not-in $excluded }))
    }
  }
  print $"check-carves-against-stage: ($claims | columns | length) packages with a carve list"

  # ── COLLISIONS: two packages claiming one path. Always a defect.
  mut owners = {}
  for pkg in ($claims | columns) {
    for p in ($claims | get $pkg) {
      let cur = ($owners | get -o $p | default [])
      $owners = ($owners | upsert $p ($cur | append $pkg))
    }
  }
  let collisions = ($owners | transpose path pkgs | where {|r| ($r.pkgs | length) > 1 })
  if not ($collisions | is-empty) {
    print ""
    print "COLLISIONS — two packages claim one path:"
    for c in ($collisions | first 40) { print $"  ($c.path)  <-  ($c.pkgs | str join ', ')" }
    print ""
  }

  if not ($unmatched | is-empty) {
    print "GLOBS MATCHING NOTHING in the real stage:"
    for u in $unmatched { print $"  ($u)" }
    print ""
  }

  let claimed = ($owners | columns | length)
  print $"check-carves-against-stage: ($claimed) of ($stage | length) stage paths are claimed by some carve"

  if not ($collisions | is-empty) {
    error make {msg: $"check-carves-against-stage: ($collisions | length) path\(s\) claimed by more than one package — the victim ships EMPTY when the other is its host dependency"}
  }
  if not ($unmatched | is-empty) {
    error make {msg: $"check-carves-against-stage: ($unmatched | length) glob\(s\) match nothing in the stage — each one fails its build"}
  }
  print "check-carves-against-stage: OK — every glob matches, and no path is claimed twice"
}
