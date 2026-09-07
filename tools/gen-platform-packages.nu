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

  # 1. `${{ target_platform }}` IS SUBSTITUTED EVERYWHERE IN THE FILE, not only
  # in the name. A generated copy exists FOR one platform, so every occurrence
  # means that platform — and leaving any of them templated is a live defect on
  # a noarch output, where target_platform is `noarch`:
  # `acpp-compiler-rt-impl`'s exact pin on
  # `acpp-compiler-rt21_${{ target_platform }}` would render
  # `acpp-compiler-rt21_noarch`, which nothing provides. The same is true of the
  # `sysroot_`, `binutils_impl_` and `ld64_` deps in the clang families,
  # although those are arch outputs where the value happens to be right.
  #
  # Other templates in the name (compiler-rt21's `${{ llvm_major }}`) are left
  # alone: measured on a throwaway package, a templated single-output name
  # resolves correctly, so substituting it would be noise.
  let name_lines = ($src | lines | where {|l| $l =~ '^  name: .*target_platform' })
  if ($name_lines | length) != 1 {
    error make {msg: $"gen-platform-packages: ($path) has ($name_lines | length) templated `  name:` lines, expected exactly one"}
  }
  let name_line = ($name_lines | first)
  let literal = ($name_line | str replace '${{ target_platform }}' $plat)

  # 2. THE SKIP. The authored recipe may or may not have one; either way the
  # generated copy must build on ITS platform only, or the N copies collide
  # exactly as N manifests over one recipe did.
  #
  # ⚠ THE AXIS DEPENDS ON `noarch:`, AND GETTING IT WRONG DELETES THE PACKAGE.
  # For a `noarch: generic` output, `target_platform` IS `noarch` — so
  # `target_platform != "linux-64"` is true on every platform, the only output
  # is skipped, and pixi fails with "there is no output defined for the package
  # <name>". That killed run 34103908648 after both stages had built, and it is
  # reproducible in three lines (measured on a throwaway package, 2026-09-07).
  # `build_platform` is the right axis there and says the true thing anyway:
  # these are noarch SELECTOR metapackages named for a platform, produced by
  # that platform's job.
  # ⚠ THE NOARCH TEST IS COMPOUND, AND BOTH HALVES EARN THEIR PLACE.
  #
  #   * `build_platform` is what is TRUE AT BUILD TIME. On a noarch output
  #     target_platform is `noarch`, so a target test skips the package on
  #     every platform and pixi then reports it has no output at all.
  #   * `target_platform` is what makes it VISIBLE TO A LOCAL CROSS-RENDER.
  #     `rattler-build --render-only --target-platform win-64` on this laptop
  #     has build_platform = linux-64, so a build_platform-only test hides the
  #     win and osx copies from every local gate — the counts drop, the
  #     superset check fails, and the sibling-mapping check reports a package
  #     that renders nowhere. Losing that is losing the instrument.
  #
  # `A != p and B != p` is false when EITHER names this platform, so the real
  # build is decided by build_platform and the local render by target_platform,
  # and no case is left ambiguous: on a win runner building the linux copy both
  # terms are true and it is correctly skipped.
  let is_noarch = ($src | lines | any {|l| $l =~ '^\s*noarch:' })
  let test = (if $is_noarch {
    $"target_platform != \"($plat)\" and build_platform != \"($plat)\""
  } else {
    $"target_platform != \"($plat)\""
  })
  let why = (if $is_noarch {
    "BOTH axes: build_platform is what holds at build time (target_platform is `noarch` here), target_platform is what keeps this copy visible to a local cross-render"
  } else {
    "target_platform: this output is architecture-specific"
  })
  # ⚠ AND A NOARCH COPY MUST IGNORE `build_platform` IN ITS VARIANT HASH.
  #
  # Referencing build_platform in the skip makes rattler-build hash it, and
  # pixi's two paths do not agree about that: the ENUMERATION computes a hash
  # without it, the BUILD computes one with it, and pixi then rejects its own
  # backend's artifact — "the build backend did not return the expected
  # package", after the archive has been written. Run 34110381268 died there,
  # and pixi retried the whole build exactly once before failing.
  #
  # `variant: ignore_keys: [build_platform]` removes it from the HASH while
  # leaving it available to the SKIP, which is the exact distinction we want:
  # build_platform decides whether this copy is built here, and says nothing
  # about the content, so it does not belong in the identity of the artifact.
  # Reproduced and fixed on a five-line throwaway package before being applied
  # here. Arch copies are unaffected — measured, their two hashes already agree
  # because nothing in them references build_platform.
  let ignore_block = (if $is_noarch {
    "\n  variant:\n    ignore_keys:\n      # See the skip above: build_platform selects the JOB, not the content.\n      - build_platform"
  } else { "" })
  if $is_noarch and ($src | lines | any {|l| $l =~ '^\s*variant:' }) {
    error make {msg: $"gen-platform-packages: ($path) already has a `variant:` block; the generated ignore_keys would duplicate it"}
  }
  let skip_lines = ($src | lines | where {|l| $l =~ '^  skip: ' })
  let with_name = ($src | str replace $name_line $literal)
  let out = (if ($skip_lines | is-empty) {
    # No authored skip: insert one directly after the literal name's build
    # `number:` line, where a skip conventionally sits.
    let anchor = ($with_name | lines | where {|l| $l =~ '^  number: ' } | first)
    $with_name | str replace $anchor $"($anchor)\n  # GENERATED: this copy exists for ($plat) alone, keyed on ($why).\n  skip: ($test)($ignore_block)"
  } else {
    let authored = ($skip_lines | first)
    let expr = ($authored | str replace "  skip: " "" | str trim)
    $with_name | str replace $authored $"  # GENERATED: the authored skip \(($expr)), AND this copy's platform.\n  # Keyed on ($why).\n  skip: ($test) or \(($expr))"
  })

  # 3. The banner goes after the schema line, which every recipe here carries.
  let schema = "# yaml-language-server: $schema=https://raw.githubusercontent.com/prefix-dev/recipe-format/main/schema.json"
  if not ($out | str contains $schema) {
    error make {msg: $"gen-platform-packages: ($path) has no schema line to anchor the generated banner to"}
  }
  # EVERY remaining `${{ target_platform }}` becomes this platform, then the
  # banner goes in after the schema line.
  #
  # The generated `skip:` above is untouched by this, and deliberately so: it
  # writes `target_platform` as a BARE jinja name, not as a `${{ … }}`
  # expression, so its axis survives. If that ever changes, the axis assertion
  # in --check is what catches it.
  # AND THE PLATFORM BOOLEANS BECOME CONSTANTS. A generated copy exists for ONE
  # platform, so `is_linux` / `is_osx` / `is_win` are not questions here — they
  # are facts, and writing them as facts removes the whole evaluation problem
  # rather than making the expression cleverer. It also makes the LOCAL render
  # faithful: `--render-only --target-platform win-64` on this laptop now shows
  # the Windows carve, because there is nothing left to evaluate against the
  # laptop's build_platform. The authored source keeps the build_platform form,
  # which is what makes it correct to read on its own.
  let bools = {is_linux: "linux-64", is_osx: "osx-arm64", is_win: "win-64"}
  mut const_out = $out
  for name in ($bools | columns) {
    let want = (if ($bools | get $name) == $plat { "true" } else { "false" })
    # NB no inline `(?m)` flag: nushell parses `(?m)` inside an interpolated
    # string as a SUBEXPRESSION calling `?m`. Matching the whole line without
    # anchors avoids needing it — the pattern is specific enough.
    let plat_of = ($bools | get $name)
    let pat = ('  ' + $name + ': ${{ build_platform == "' + $plat_of + '" }}')
    $const_out = ($const_out | str replace $pat $"  ($name): ($want)  # GENERATED: constant for ($plat)")
  }
  ($const_out
    | str replace --all '${{ target_platform }}' $plat
    | str replace $schema $"($schema)\n($BANNER)")
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
  # THE PROPERTY, asserted on what is on disk rather than on what the generator
  # believes it wrote: a noarch output must never be skipped on target_platform.
  # That is the defect that cost run 34103908648, and the assertion is what
  # stops it coming back through a hand edit or a future generator change.
  mut axis_bad = []
  for fam in $FAMILIES {
    for plat in $fam.plats {
      let out = $"packages/($fam.dir)-($plat)/recipe.yaml"
      if not ($out | path exists) { continue }
      let t = (open --raw $out)
      let noarch = ($t | lines | any {|l| $l =~ '^\s*noarch:' })
      let skips = ($t | lines | where {|l| $l =~ '^\s*skip:' })
      # A noarch skip MUST mention build_platform. It may ALSO mention
      # target_platform — the compound form is deliberate, so the copy stays
      # visible to a local cross-render — but a target-only test is the defect:
      # target_platform is `noarch` on these outputs, so it skips everywhere and
      # pixi reports the package as having no output at all.
      if $noarch and ($skips | any {|s| ($s =~ 'target_platform') and (not ($s =~ 'build_platform')) }) {
        $axis_bad = ($axis_bad | append $"($out) is noarch and skips on target_platform ALONE — that skips it EVERYWHERE, and pixi then reports 'there is no output defined for the package'")
      }
      if $noarch and (not ($skips | any {|s| $s =~ 'build_platform' })) {
        $axis_bad = ($axis_bad | append $"($out) is noarch and its skip never mentions build_platform — the only axis that means anything at build time there")
      }
      # ⚠ A NOARCH COPY THAT REFERENCES build_platform MUST IGNORE IT IN THE
      # HASH. Otherwise pixi's enumeration and its build compute different
      # variant hashes and pixi rejects its own backend's artifact AFTER the
      # archive is written — run 34110381268, which it retried once first.
      if $noarch and ($t | str contains "build_platform") {
        let ignores = ($t | lines | any {|l| $l =~ '^\s*- build_platform\s*$' })
        if not $ignores {
          $axis_bad = ($axis_bad | append $"($out) references build_platform but does not list it under `variant: ignore_keys:` — its enumeration and build hashes will diverge and pixi will reject the built package")
        }
      }
      # The platform booleans must be CONSTANTS in a generated copy. If one is
      # still an expression, the recipe is deciding at build time what the
      # generator already knows, and the local render stops being faithful.
      let live_bools = ($t | lines | where {|l| $l =~ '^\s*is_(linux|osx|win):\s*\$\{\{' })
      for b in $live_bools {
        $axis_bad = ($axis_bad | append $"($out) still evaluates a platform boolean at build time: ($b | str trim)")
      }
      if (not $noarch) and ($skips | any {|s| $s =~ 'build_platform' }) {
        $axis_bad = ($axis_bad | append $"($out) is architecture-specific but skips on build_platform — wrong axis for a cross-capable output")
      }
      # ⚠ AND NO BARE PLATFORM SELECTOR ANYWHERE IN A NOARCH RECIPE. `linux`,
      # `osx`, `win` and `unix` are all derived from target_platform, which is
      # `noarch` on these outputs — so every one of them is FALSE and an
      # if/elif/else chain silently takes its LAST branch. That put the Windows
      # carve glob into the linux package and failed run 34105145758. The
      # `is_linux` / `is_osx` / `is_win` context booleans, keyed on
      # build_platform, are the replacement; this asserts none of the bare
      # names came back.
      if $noarch {
        # The selector has to be matched as an IDENTIFIER, not as any occurrence
        # of the word: `"lib/linux/**"` and `libclang_rt.osx.a` are paths, and
        # `is_linux: ${{ build_platform == "linux-64" }}` is the FIX. So look
        # for the name in an operator position — after if/and/or/not — or as a
        # whole YAML `if:` value.
        # ONE REGEX ON ONE LINE. A multi-line boolean chain does not survive
        # nushell 0.114 either way round — a leading `and`/`or` parses as a
        # command, a trailing one is an incomplete expression — and it fails at
        # RUN time inside the closure, where the parse check never reaches it.
        # This project has now lost four constructs to that; the shape is the
        # fix.
        let selector = '(?:^|[ (])(?:if|and|or|not)\s+(?:linux|osx|win|unix)\b|^\s*-?\s*if:\s*(?:linux|osx|win|unix)\s*$'
        let bare = ($t | lines | enumerate | where {|r| ($r.item =~ $selector) and (not ($r.item | str trim | str starts-with '#')) })
        for b in $bare {
          $axis_bad = ($axis_bad | append $"($out):($b.index + 1) uses a bare platform selector in a NOARCH recipe — it is FALSE there, use is_linux/is_osx/is_win: ($b.item | str trim)")
        }
      }
    }
  }
  if not ($axis_bad | is-empty) {
    for b in $axis_bad { print $"FAIL ($b)" }
    error make {msg: $"gen-platform-packages: ($axis_bad | length) generated recipe\(s\) skip on the wrong platform axis"}
  }

  if $check {
    print $"gen-platform-packages: checked ($n) generated recipe\(s\) — every skip axis matches its noarch-ness"
    if not ($drifted | is-empty) {
      for d in $drifted { print $"DRIFT ($d)" }
      error make {msg: $"gen-platform-packages: ($drifted | length) generated recipe\(s\) do not match their authored source — run the generator"}
    }
    print "gen-platform-packages: OK — every generated recipe matches its authored source"
  } else {
    print $"gen-platform-packages: wrote ($n) per-platform recipe\(s\)"
  }
}
