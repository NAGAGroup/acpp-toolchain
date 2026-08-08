#!/usr/bin/env nu
# Generate nightly/recipe.yaml as a transformation of release/recipe.yaml.
#
# The two lanes are structurally identical; only pins, names and version
# semantics differ. Keeping nightly GENERATED (rather than hand-maintained)
# means a change to the release recipe can never silently skip the nightly
# lane. CI runs `--check` and fails if the committed file is stale.
#
# This is a RAW TEXT transform on purpose: round-tripping the recipe through
# a YAML parser would discard every comment, and the comments carry the
# partition rationale (which file belongs to which output, and why).
#
#   nu shared/gen-nightly.nu           # write nightly/recipe.yaml
#   nu shared/gen-nightly.nu --check   # exit 1 if the committed file is stale

const LLVM_SHA_RELEASE = "6898f963c8e938981e6c4a302e83ec5beb4630147c7311183cf61069af16333d"
const LLVM_SHA_NIGHTLY = "4633a23617fa31a3ea51242586ea7fb1da7140e426bd62fc164261fe036aa142"
const SPIRV_COMMIT_RELEASE = "f0ae76f12c62ede090e57ece8c986f4c3c971a71"
const SPIRV_COMMIT_NIGHTLY = "3d3f0dece590232aab1851f1bea860c2a381ec34"
const SPIRV_SHA_RELEASE = "da7f91cc0d1f22fe6bb3806fd964366296109c20b462f524f60418ae0bc5a16a"
const SPIRV_SHA_NIGHTLY = "075b9f62fdf7fb52a24ef88fc7986f227b1fb4b149d0601c878efad2a8e5f703"

# ── header ────────────────────────────────────────────────────────────────
const HEADER_RELEASE = '# Release lane — ONE multi-output recipe (design v3 §D1): the staging output
# runs the LLVM+AdaptiveCpp build once; package outputs carve its prefix via
# files: globs (audited zero-clobber partition). Build with --experimental.'

const HEADER_NIGHTLY = '# Nightly lane — tracks AdaptiveCpp develop against the next LLVM (design v3
# §D1). GENERATED from release/recipe.yaml by shared/gen-nightly.nu — DO NOT
# EDIT BY HAND; edit the release recipe and run `pixi run gen-nightly`.
# Version is date-injected (ACPP_NIGHTLY_DATE) and the acpp source is pinned
# to the SHA the CI skip-check resolved (ACPP_NIGHTLY_SHA), so the staging
# cache key rotates deterministically per upstream commit.'

# ── context block ─────────────────────────────────────────────────────────
const CONTEXT_RELEASE = 'context:
  llvm_version: "20.1.8"
  llvm_major: "20"
  llvm_major_next: "21"
  llvm_maj_min: "20.1"
  acpp_version: "25.10.0"
  version: ${{ acpp_version ~ "_llvm" ~ llvm_version }}'

const CONTEXT_NIGHTLY = 'context:
  llvm_version: "21.1.8"
  llvm_major: "21"
  llvm_major_next: "22"
  llvm_maj_min: "21.1"
  acpp_version: ${{ env.get("ACPP_NIGHTLY_DATE", default="0.dev0") }}
  # CI resolves develop HEAD and passes it; local builds float on the branch.
  acpp_commit: ${{ env.get("ACPP_NIGHTLY_SHA", default="develop") }}
  version: ${{ acpp_version ~ "_llvm" ~ llvm_version }}'

# ── AdaptiveCpp source: pinned tarball -> git at a resolved rev ────────────
const ACPP_SRC_RELEASE = '  - url: https://github.com/AdaptiveCpp/AdaptiveCpp/archive/9f842c701a599107cc6d117d3539f971036363a1.tar.gz
    sha256: 816cfdfce0fade314533fc5497f16bfa8419b9d96e47fb39e9e134c3d2cb6d1b
    target_directory: AdaptiveCpp'

const ACPP_SRC_NIGHTLY = '  - git: https://github.com/AdaptiveCpp/AdaptiveCpp.git
    rev: ${{ acpp_commit }}
    target_directory: AdaptiveCpp'

# Renames run in three phases so no replacement can be re-matched by a later,
# shorter pattern (a naive sequential pass turns acpp-runtime-cuda into
# acpp-runtime-nightly-cuda-nightly). Phase 1 parks the cross-lane exclusion
# constraints that ALREADY name nightly packages; phase 2 rewrites release
# names to placeholders; phase 3 resolves every placeholder.
def park-pairs [] {
  [[from, to];
   ["acpp-runtime-activate.sh", "@PROT_ACT@"]      # a shipped file, never a package
   ["acpp-clangxx-nightly_linux-64", "@X_CLANGXX@"]
   ["acpp-clang-cl-nightly_win-64", "@X_CLANGCL_WIN@"]
   ["acpp-clangxx-nightly_win-64", "@X_CLANGXX_WIN@"]
   ["acpp-clang-nightly_win-64", "@X_CLANG_WIN@"]
   ["acpp-clang-nightly_linux-64", "@X_CLANG@"]
   ["acpp-runtime-cuda-nightly", "@X_CUDA@"]
   ["acpp-runtime-intel-nightly", "@X_INTEL@"]
   ["acpp-runtime-nightly", "@X_RT@"]
   ["acpp-llvm-dev-nightly", "@X_DEV@"]
   ["acpp-tools-nightly", "@X_TOOLS@"]
   ["acpp-lldb-nightly", "@X_LLDB@"]
   ["acpp-nightly", "@X_ACPP@"]]
}

def rename-pairs [] {
  [[from, to];
   ["acpp-clangxx_linux-64", "@N_CLANGXX@"]
   ["acpp-clang-cl_win-64", "@N_CLANGCL_WIN@"]
   ["acpp-clangxx_win-64", "@N_CLANGXX_WIN@"]
   ["acpp-clang_win-64", "@N_CLANG_WIN@"]
   ["acpp-clang_linux-64", "@N_CLANG@"]
   ["acpp-runtime-cuda", "@N_CUDA@"]
   ["acpp-runtime-intel", "@N_INTEL@"]
   ["acpp-runtime", "@N_RT@"]
   ["acpp-llvm-dev", "@N_DEV@"]
   ["acpp-tools", "@N_TOOLS@"]
   ["acpp-lldb", "@N_LLDB@"]
   ["pin_subpackage('acpp',", "pin_subpackage('@N_ACPP@',"]
   ["name: acpp\n", "name: @N_ACPP@\n"]]
}

def unpark-pairs [] {
  [[from, to];
   # cross-lane exclusions point at the RELEASE names
   ["@X_CLANGXX@", "acpp-clangxx_linux-64"]
   ["@X_CLANGXX_WIN@", "acpp-clangxx_win-64"]
   ["@X_CLANGCL_WIN@", "acpp-clang-cl_win-64"]
   ["@X_CLANG_WIN@", "acpp-clang_win-64"]
   ["@X_CLANG@", "acpp-clang_linux-64"]
   ["@X_CUDA@", "acpp-runtime-cuda"]
   ["@X_INTEL@", "acpp-runtime-intel"]
   ["@X_RT@", "acpp-runtime"]
   ["@X_DEV@", "acpp-llvm-dev"]
   ["@X_TOOLS@", "acpp-tools"]
   ["@X_LLDB@", "acpp-lldb"]
   ["@X_ACPP@", "acpp"]
   # this lane's own packages
   ["@N_CLANGXX@", "acpp-clangxx-nightly_linux-64"]
   ["@N_CLANGXX_WIN@", "acpp-clangxx-nightly_win-64"]
   ["@N_CLANGCL_WIN@", "acpp-clang-cl-nightly_win-64"]
   ["@N_CLANG_WIN@", "acpp-clang-nightly_win-64"]
   ["@N_CLANG@", "acpp-clang-nightly_linux-64"]
   ["@N_CUDA@", "acpp-runtime-cuda-nightly"]
   ["@N_INTEL@", "acpp-runtime-intel-nightly"]
   ["@N_RT@", "acpp-runtime-nightly"]
   ["@N_DEV@", "acpp-llvm-dev-nightly"]
   ["@N_TOOLS@", "acpp-tools-nightly"]
   ["@N_LLDB@", "acpp-lldb-nightly"]
   ["@N_ACPP@", "acpp-nightly"]
   ["@PROT_ACT@", "acpp-runtime-activate.sh"]]
}

def tail-pairs [] {
  [[from, to];
   # date-based nightly versions carry no range semantics: pin exactly
   ['- acpp-runtime-nightly >=${{ acpp_version }},<25.11', '- acpp-runtime-nightly ==${{ version }}']
   ["name: acpp-toolchain\n", "name: acpp-toolchain-nightly\n"]
   ['summary: AdaptiveCpp SYCL toolchain (LLVM ${{ llvm_major }} linked-in, generic SSCP)',
    'summary: AdaptiveCpp SYCL toolchain nightly (develop @ LLVM ${{ llvm_major }}, generic SSCP)']]
}

def apply-pairs [text: string, pairs: table] {
  mut out = $text
  for p in $pairs { $out = ($out | str replace --all $p.from $p.to) }
  $out
}

def generate [src: path] {
  mut s = (open --raw $src)
  $s = ($s | str replace --all $HEADER_RELEASE $HEADER_NIGHTLY)
  $s = ($s | str replace --all $CONTEXT_RELEASE $CONTEXT_NIGHTLY)
  $s = ($s | str replace --all $ACPP_SRC_RELEASE $ACPP_SRC_NIGHTLY)
  $s = ($s | str replace --all $LLVM_SHA_RELEASE $LLVM_SHA_NIGHTLY)
  $s = ($s | str replace --all $SPIRV_COMMIT_RELEASE $SPIRV_COMMIT_NIGHTLY)
  $s = ($s | str replace --all $SPIRV_SHA_RELEASE $SPIRV_SHA_NIGHTLY)
  $s = (apply-pairs $s (park-pairs))
  $s = (apply-pairs $s (rename-pairs))
  $s = (apply-pairs $s (unpark-pairs))
  $s = (apply-pairs $s (tail-pairs))
  $s
}

def main [--check] {
  let root = ($env.FILE_PWD | path dirname)
  let src = ($root | path join "release" "recipe.yaml")
  let dst = ($root | path join "nightly" "recipe.yaml")
  let out = (generate $src)

  if $check {
    let cur = (if ($dst | path exists) { open --raw $dst } else { "" })
    if $cur != $out {
      print --stderr "nightly/recipe.yaml is STALE — run `pixi run gen-nightly`"
      exit 1
    }
    print "nightly/recipe.yaml is up to date"
  } else {
    $out | save --force $dst
    let n = ($out | str length)
    print $"wrote ($dst) — ($n) bytes"
  }
}
