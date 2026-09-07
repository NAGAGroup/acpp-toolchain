# gen-platform-packages.nu — generate the per-platform packages of every
# `${{ target_platform }}`-templated family, from ONE authored recipe each.
#
# WHY THIS EXISTS, in one paragraph. pixi matches a source package by its
# manifest `[package] name`, never by rendering the recipe — proved on a
# two-package throwaway workspace, and it is what killed run 34097701602 three
# levels down a host solve. A recipe emitting
# `acpp-clang_impl_${{ target_platform }}` therefore needs one MANIFEST per
# platform, each named for what that platform emits. But several manifests
# pointing at ONE templated recipe all render the SAME name on a given
# platform, and pixi refuses that outright: "packages X and Y both produce an
# output named Z". So each platform needs its own RECIPE too, with the name
# spelled literally and a skip that leaves the file to its own platform.
#
# AUTHORED ONCE, GENERATED N TIMES. Keeping three hand-maintained copies of a
# ninety-line slice list is precisely the drift this repo has avoided
# everywhere else, so the family's recipe stays the single source of truth in
# `packages/<family>/recipe.yaml` — a directory with NO manifest, so it is not
# itself a package — and this writes the per-platform copies beside it.
# `--check` regenerates in memory and fails on any difference, which is what
# makes the generated files safe to commit: a hand edit to a generated copy is
# a red build, not a silent divergence. Same shape as `main`'s
# `shared/gen-nightly.nu`, which generates the nightly lane from the release
# one for the same reason.
#
#   pixi run -e packaging nu tools/gen-platform-packages.nu
#   pixi run -e packaging nu tools/gen-platform-packages.nu --check

# The families and the platforms each is built for. The platform list restates
# the authored recipe's own `skip:` — clangdev's impl outputs are skipped on
# win upstream (no win artifact exists), compiler-rt's are not — and the
# generator ASSERTS the two agree rather than trusting this list.
const FAMILIES = [
  {dir: "acpp-clang-impl", plats: ["linux-64" "osx-arm64"]}
  {dir: "acpp-clangxx-impl", plats: ["linux-64" "osx-arm64"]}
  {dir: "acpp-compiler-rt-impl", plats: ["linux-64" "win-64" "osx-arm64"]}
  {dir: "acpp-compiler-rt21-impl", plats: ["linux-64" "win-64" "osx-arm64"]}
]

const BANNER = "#
# ⚠ GENERATED FILE — DO NOT EDIT. Written by tools/gen-platform-packages.nu
# from ../<family>/recipe.yaml, which is the authored source of truth. CI runs
# the generator with --check, so an edit here is a red build.
#
# WHY IT HAS TO EXIST: pixi matches a source package by its MANIFEST name, so a
# templated recipe needs one manifest per platform — and several manifests
# sharing one TEMPLATED recipe would all emit the same name on a given
# platform, which pixi refuses. Hence a literal name and a platform skip.
"

def generate [dir: string, plat: string] {
  let path = $"packages/($dir)/recipe.yaml"
  let src = (open --raw $path)

  # 1. THE NAME. Only `${{ target_platform }}` is substituted — any other
  # template in the name line (compiler-rt21's `${{ llvm_major }}`) is left
  # alone, because it is not what pixi matches on and the authored recipe is
  # entitled to it.
  let name_lines = ($src | lines | where {|l| $l =~ '^  name: .*target_platform' })
  if ($name_lines | length) != 1 {
    error make {msg: $"gen-platform-packages: ($path) has ($name_lines | length) templated `  name:` lines, expected exactly one"}
  }
  let name_line = ($name_lines | first)
  let literal = ($name_line | str replace '${{ target_platform }}' $plat)

  # 2. THE SKIP. The authored recipe may or may not have one; either way the
  # generated copy must build on ITS platform only, or the N copies collide
  # exactly as N manifests over one recipe did.
  let skip_lines = ($src | lines | where {|l| $l =~ '^  skip: ' })
  let with_name = ($src | str replace $name_line $literal)
  let out = (if ($skip_lines | is-empty) {
    # No authored skip: insert one directly after the literal name's build
    # `number:` line, where a skip conventionally sits.
    let anchor = ($with_name | lines | where {|l| $l =~ '^  number: ' } | first)
    $with_name | str replace $anchor $"($anchor)\n  # GENERATED: this copy exists for ($plat) alone.\n  skip: target_platform != \"($plat)\""
  } else {
    let authored = ($skip_lines | first)
    let expr = ($authored | str replace "  skip: " "" | str trim)
    $with_name | str replace $authored $"  # GENERATED: the authored skip \(($expr)), AND this copy's platform.\n  skip: target_platform != \"($plat)\" or \(($expr))"
  })

  # 3. The banner goes after the schema line, which every recipe here carries.
  let schema = "# yaml-language-server: $schema=https://raw.githubusercontent.com/prefix-dev/recipe-format/main/schema.json"
  if not ($out | str contains $schema) {
    error make {msg: $"gen-platform-packages: ($path) has no schema line to anchor the generated banner to"}
  }
  $out | str replace $schema $"($schema)\n($BANNER)"
}

def main [--check] {
  mut n = 0
  mut drifted = []
  for fam in $FAMILIES {
    for plat in $fam.plats {
      let out = $"packages/($fam.dir)-($plat)/recipe.yaml"
      let want = (generate $fam.dir $plat)
      if $check {
        if not ($out | path exists) {
          $drifted = ($drifted | append $"($out) is MISSING")
        } else if (open --raw $out) != $want {
          $drifted = ($drifted | append $"($out) differs from what its authored recipe generates")
        }
      } else {
        mkdir ($out | path dirname)
        $want | save -f $out
      }
      $n = $n + 1
    }
  }
  if $n < 4 {
    error make {msg: "gen-platform-packages: fewer than four generated recipes — the family list is broken, and a check over nothing is not a check"}
  }
  if $check {
    print $"gen-platform-packages: checked ($n) generated recipe\(s\)"
    if not ($drifted | is-empty) {
      for d in $drifted { print $"DRIFT ($d)" }
      error make {msg: $"gen-platform-packages: ($drifted | length) generated recipe\(s\) do not match their authored source — run the generator"}
    }
    print "gen-platform-packages: OK — every generated recipe matches its authored source"
  } else {
    print $"gen-platform-packages: wrote ($n) per-platform recipe\(s\)"
  }
}
