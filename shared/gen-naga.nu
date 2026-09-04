#!/usr/bin/env nu
# Generate naga/recipe.yaml as a transformation of nightly/recipe.yaml.
#
# The naga lane builds OUR FORK of AdaptiveCpp (NAGAGroup/AdaptiveCpp) for
# internal development. It is generated from the NIGHTLY lane rather than from
# release, because it shares everything that makes nightly nightly: the same
# LLVM major, a git source at a resolved rev, a date version, and therefore
# exact pins. Chaining release -> nightly -> naga keeps one source of truth;
# CI runs --check on both generators.
#
# Two deltas do real work beyond renaming:
#
#   1. The fork already CONTAINS the shared patches as commits (its branch is
#      cut from f2600750 plus 0001-0003), so applying them again would fail.
#   2. The mutex cannot separate naga from nightly: both lanes are LLVM 21, so
#      both export acpp-llvm >=21,<22.0a0 and one mutex package satisfies both.
#      Only name exclusions keep them apart, and since nightly and release are
#      deliberately left untouched, every exclusion has to be declared HERE —
#      against BOTH other lanes.
#
#   nu shared/gen-naga.nu           # write naga/recipe.yaml
#   nu shared/gen-naga.nu --check   # exit 1 if the committed file is stale

const HEADER_NIGHTLY = '# Nightly lane — tracks AdaptiveCpp develop against the next LLVM (design v3
# §D1). GENERATED from release/recipe.yaml by shared/gen-nightly.nu — DO NOT
# EDIT BY HAND; edit the release recipe and run `pixi run gen-nightly`.
# Version is date-injected (ACPP_NIGHTLY_DATE) and the acpp source is pinned
# to the SHA the CI skip-check resolved (ACPP_NIGHTLY_SHA), so the staging
# cache key rotates deterministically per upstream commit.'

const HEADER_NAGA = '# naga lane — builds the NAGA fork of AdaptiveCpp for internal development.
# GENERATED from nightly/recipe.yaml by shared/gen-naga.nu — DO NOT EDIT BY
# HAND; edit the release recipe, run `pixi run gen-nightly`, then
# `pixi run gen-naga`.
# Version is date-injected (ACPP_NAGA_DATE) and the source is pinned to an
# explicit fork SHA (ACPP_NAGA_SHA) — the fork is not a moving branch the way
# develop is, so a publish names the commit it shipped.
# These packages are DEV builds and are not peers of the release and nightly
# families; they carry exclusions against both.'

# ── context: env var names and the default rev ─────────────────────────────
const CONTEXT_NIGHTLY = '  acpp_version: ${{ env.get("ACPP_NIGHTLY_DATE", default="0.dev0") }}
  # CI resolves develop HEAD and passes it; local builds float on the branch.
  acpp_commit: ${{ env.get("ACPP_NIGHTLY_SHA", default="develop") }}'

const CONTEXT_NAGA = '  acpp_version: ${{ env.get("ACPP_NAGA_DATE", default="0.dev0") }}
  # An explicit fork SHA; the branch default is for local builds only.
  acpp_commit: ${{ env.get("ACPP_NAGA_SHA", default="naga/retarget-context") }}'

# ── source: upstream at a rev, patched -> the fork at a rev, unpatched ─────
# The fork carries 0001-0003 as commits, so re-applying them would fail.
const ACPP_SRC_NIGHTLY = '      - git: https://github.com/AdaptiveCpp/AdaptiveCpp.git
        rev: ${{ acpp_commit }}
        target_directory: AdaptiveCpp
        patches:
          - ../shared/patches/0001-llvmspirv-allow-local-source-dir.patch
          # Level Zero backend includes a glibc-internal header; breaks on win
          - ../shared/patches/0002-ze-use-cstdint-not-glibc-internal-header.patch
          # Level Zero backend links with GNU-style -lze_loader; lld-link drops it
          - ../shared/patches/0003-ze-find-loader-library-portably.patch'

const ACPP_SRC_NAGA = '      - git: https://github.com/NAGAGroup/AdaptiveCpp.git
        rev: ${{ acpp_commit }}
        target_directory: AdaptiveCpp
        # No patches: the fork branch is cut from the base these patches were
        # written against and carries all three as commits.'

# Every nightly package name contains "-nightly"; the release names it excludes
# do not. So unlike gen-nightly, these patterns cannot re-match an exclusion
# line, and a single ordered pass is safe. Longest-first is kept as the
# invariant that makes the table safe to extend.
def rename-pairs [] {
  [[from, to];
   ["acpp-compiler-rt-nightly", "naga-acpp-compiler-rt"]
   ["acpp-clangxx-nightly_linux-64", "naga-acpp-clangxx_linux-64"]
   ["acpp-clang-cl-nightly_win-64", "naga-acpp-clang-cl_win-64"]
   ["acpp-clangxx-nightly_win-64", "naga-acpp-clangxx_win-64"]
   ["acpp-clang-nightly_win-64", "naga-acpp-clang_win-64"]
   ["acpp-clang-nightly_linux-64", "naga-acpp-clang_linux-64"]
   ["acpp-runtime-cuda-nightly", "naga-acpp-runtime-cuda"]
   ["acpp-runtime-intel-nightly", "naga-acpp-runtime-intel"]
   ["acpp-runtime-nightly", "naga-acpp-runtime"]
   ["acpp-llvm-dev-nightly", "naga-acpp-llvm-dev"]
   ["acpp-toolchain-nightly", "naga-acpp-toolchain"]
   ["acpp-tools-nightly", "naga-acpp-tools"]
   ["acpp-lldb-nightly", "naga-acpp-lldb"]
   ["acpp-nightly", "naga-acpp"]]
}

# Release name -> its nightly twin. Used to ADD an exclusion beside every
# release exclusion the nightly recipe already carries, so the naga lane
# forbids both families. acpp-llvm is absent on purpose: it is the SHARED
# mutex, not a lane package, and must never be excluded.
def twin-pairs [] {
  [[release, nightly];
   ["acpp-compiler-rt", "acpp-compiler-rt-nightly"]
   ["acpp-clangxx_linux-64", "acpp-clangxx-nightly_linux-64"]
   ["acpp-clang-cl_win-64", "acpp-clang-cl-nightly_win-64"]
   ["acpp-clangxx_win-64", "acpp-clangxx-nightly_win-64"]
   ["acpp-clang_win-64", "acpp-clang-nightly_win-64"]
   ["acpp-clang_linux-64", "acpp-clang-nightly_linux-64"]
   ["acpp-runtime-cuda", "acpp-runtime-cuda-nightly"]
   ["acpp-runtime-intel", "acpp-runtime-intel-nightly"]
   ["acpp-runtime", "acpp-runtime-nightly"]
   ["acpp-llvm-dev", "acpp-llvm-dev-nightly"]
   ["acpp-tools", "acpp-tools-nightly"]
   ["acpp-lldb", "acpp-lldb-nightly"]
   ["acpp", "acpp-nightly"]]
}

# Add the nightly twin beside every release exclusion, preserving indentation.
# Only "<0.0a0" lines naming an acpp package are touched: the same constraint
# appears for conda-forge packages (clang_linux-64, libllvm21) which have no
# twin, and version-window constraints must not be duplicated at all.
def add-nightly-exclusions [text: string] {
  let twins = (twin-pairs)
  mut out = []
  for line in ($text | lines) {
    $out = ($out | append $line)
    let trimmed = ($line | str trim)
    if ($trimmed | str starts-with "- acpp") and ($trimmed | str ends-with "<0.0a0") {
      let name = ($trimmed | str replace "- " "" | str replace " <0.0a0" "")
      let match = ($twins | where release == $name)
      if ($match | is-not-empty) {
        let indent = ($line | str replace --regex '^(\s*).*$' '$1')
        $out = ($out | append $"($indent)- ($match.nightly.0) <0.0a0")
      }
    }
  }
  ($out | str join "\n") + "\n"
}

def apply-pairs [text: string, pairs: table] {
  mut out = $text
  for p in $pairs { $out = ($out | str replace --all $p.from $p.to) }
  $out
}

def generate [src: path] {
  mut s = (open --raw $src)

  # Order matters: the twins are literal nightly names, so they must be added
  # AFTER every nightly name has been renamed away, or they would be renamed
  # too.
  $s = ($s | str replace --all $HEADER_NIGHTLY $HEADER_NAGA)
  $s = ($s | str replace --all $CONTEXT_NIGHTLY $CONTEXT_NAGA)
  $s = ($s | str replace --all $ACPP_SRC_NIGHTLY $ACPP_SRC_NAGA)
  $s = (apply-pairs $s (rename-pairs))
  $s = (add-nightly-exclusions $s)

  # Guard against SILENT substitution misses: a block replacement whose
  # indentation drifted would leave the nightly form in place and the lane
  # would build the wrong source, or fail on already-applied patches, without
  # anything here saying so.
  for leftover in [
    "AdaptiveCpp/AdaptiveCpp.git"        # upstream source, not ours
    "shared/patches/0001"                # patches the fork already carries
    "ACPP_NIGHTLY_DATE"
    "ACPP_NIGHTLY_SHA"
    "name: acpp-"                        # a lane output that kept its old name
  ] {
    if ($s | str contains $leftover) {
      error make {msg: $"gen-naga: '($leftover)' survived into the naga output — a substitution pattern no longer matches nightly/recipe.yaml"}
    }
  }

  # Every lane output must forbid both other families. Counting is what catches
  # a twin table that fell behind the recipe's outputs.
  let own = ($s | lines | where {|l| ($l | str trim) starts-with "name: naga-acpp" } | length)
  let excl = ($s | lines | where {|l| ($l | str trim) ends-with "<0.0a0" } | length)
  print $"naga outputs: ($own), exclusion lines: ($excl)"

  $s
}

def main [--check] {
  let root = ($env.FILE_PWD | path dirname)
  let src = ($root | path join "nightly" "recipe.yaml")
  let dst = ($root | path join "naga" "recipe.yaml")
  let out = (generate $src)

  if $check {
    let cur = (if ($dst | path exists) { open --raw $dst } else { "" })
    if $cur != $out {
      print --stderr "naga/recipe.yaml is STALE — run `pixi run gen-naga`"
      exit 1
    }
    print "naga/recipe.yaml is up to date"
  } else {
    mkdir ($dst | path dirname)
    $out | save --force $dst
    print $"wrote ($dst) — ($out | str length) bytes"
  }
}
