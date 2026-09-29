#!/usr/bin/env nu
# render-install-win.nu — render + install the acpp compiler activation scripts
# for win-64 AND win-arm64 from the VENDORED conda-forge clang-win-activation
# templates (pinned ref in vendor/clang-win-activation/PINNED_REF).
#
# Windows activation is a DIFFERENT LINEAGE from the linux ctng one:
#   * three shells per side — .bat (cmd), .ps1 (PowerShell), .sh (bash/MSYS)
#   * ordering is encoded in the FILENAME, not by a `~` sort trick:
#     `vs<YEAR>_y-*` sorts after the vs<YEAR> compiler vars, and `_z-*`
#     (clangxx) must come after `_y-*` (clang) because the clangxx script
#     reuses CPPFLAGS_USED that the clang script sets.
#   * only the .sh side carries deactivate scripts / CONDA_BACKUP_ machinery;
#     cmd/PowerShell activation is plain `set`.
#
# Everything is a faithful port EXCEPT the sections marked "ACPP DELTA".
#
# Usage: nu render-install-win.nu {clang|clangxx|clang-cl} <llvm_major> <target_platform>
#
# WIN-ARM64: our vendored templates predate the upstream feedstock's own
# @BUILTINS_ARCH@ placeholder (added there to parameterise the hardcoded
# "x86_64" in clang_rt.builtins-x86_64.lib for cross-arch support) — they
# still hardcode x86_64. Rather than re-vendor, `builtins-arch-fix` below
# swaps that literal string for win-arm64, to the SAME "aarch64" value the
# current feedstock's install-pkg.bat computes
# (`set "BUILTINS_ARCH=aarch64"` when `%cross_target_platform%`=="win-arm64",
# confirmed by fetching the feedstock's current main at hand-off time).

const VSYEAR = "2026"

def chost-for [target_platform: string] {
  if $target_platform == "win-arm64" { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" }
}

# FINAL_* are the ctng linux64 flags minus -fPIC/-fno-plt (see vendored cbc).
# WIN-ARM64 drops -march=nocona -mtune=haswell (x86-only flags) — confirmed
# against the feedstock's OWN conda_build_config.yaml, whose `[win and
# arm64]`-selected FINAL_CFLAGS/FINAL_CXXFLAGS/FINAL_CL_FLAGS entries carry
# the same flag SET with march/mtune absent (quoted in the hand-off report).
def final-cflags [target_platform: string] {
  let base = "-march=nocona -mtune=haswell -ftree-vectorize -fstack-protector-strong -O2 -ffunction-sections -pipe"
  if $target_platform == "win-arm64" { $base | str replace "-march=nocona -mtune=haswell " "" } else { $base }
}

def final-cxxflags [target_platform: string] {
  let base = "-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -march=nocona -mtune=haswell -ftree-vectorize -fstack-protector-strong -O2 -ffunction-sections -pipe"
  if $target_platform == "win-arm64" { $base | str replace "-march=nocona -mtune=haswell " "" } else { $base }
}

# clang-cl takes MSVC-style flags; both @CFLAGS@ and @CXXFLAGS@ render to this.
def final-cl-flags [target_platform: string] {
  let base = "/Oi /O2 /GS /Gy /MD -march=nocona -mtune=haswell -fuse-ld=lld"
  if $target_platform == "win-arm64" { $base | str replace "-march=nocona -mtune=haswell " "" } else { $base }
}

## BUG FIX (found by isolated test — parse-time error, not runtime): Nushell
# custom `def`s do NOT bind piped input to the first declared positional
# parameter the way builtins like `str replace` do — piped input is only
# reachable via `$in`. The original two-positional-param form, called as
# `| builtins-arch-fix $target_platform`, bound `$target_platform` to the
# FIRST param (`text`) and left the second (`target_platform`) unfilled,
# which is a parse error `try`/`catch` cannot even catch. Fixed by taking
# only `target_platform` as an explicit param and reading the piped text
# via `$in`.
def builtins-arch-fix [target_platform: string] {
  let text = $in
  if $target_platform == "win-arm64" {
    $text | str replace --all "clang_rt.builtins-x86_64.lib" "clang_rt.builtins-aarch64.lib"
  } else {
    $text
  }
}

# ACPP DELTA — the SYCL environment, added on the CXX side only (mirrors the
# linux port). ACPP_TARGETS respects a pre-set value; generic SSCP is the only
# compiled flow, so one binary JITs per device. ACPP_CPU_CXX mirrors
# ACPP_CLANG (the fork's CPU JIT driver), same as the linux/osx ports. The
# dead ACPP_COMPILER_DIR (never read by anything) is gone. Paths use the
# conda Windows layout (%CONDA_PREFIX%\Library).
const ACPP_BAT = '
REM ---- ACPP DELTA: SYCL environment -------------------------------------
if not defined ACPP_TARGETS set "ACPP_TARGETS=generic"
set "ACPP_CLANG=%CONDA_PREFIX%\Library\bin\clang++.exe"
set "ACPP_CPU_CXX=%CONDA_PREFIX%\Library\bin\clang++.exe"
'

const ACPP_PS1 = '
# ---- ACPP DELTA: SYCL environment ---------------------------------------
if (-not $Env:ACPP_TARGETS) { $Env:ACPP_TARGETS = "generic" }
$Env:ACPP_CLANG = "$Env:CONDA_PREFIX\Library\bin\clang++.exe"
$Env:ACPP_CPU_CXX = "$Env:CONDA_PREFIX\Library\bin\clang++.exe"
'

# For the .sh side the delta rides the existing _tc_activation call, so
# deactivation symmetry comes for free (same as linux).
const ACPP_SH_ENTRIES = '  "ACPP_TARGETS,${ACPP_TARGETS:-generic}" \
  "ACPP_CLANG,${CONDA_PREFIX}/Library/bin/clang++.exe" \
  "ACPP_CPU_CXX,${CONDA_PREFIX}/Library/bin/clang++.exe" \
'

def render [text: string, llvm_major: string, side: string, target_platform: string] {
  # clang-cl is a single driver for both languages, so both flag slots take
  # the MSVC-style flag set.
  let cflags = (if $side == "clang-cl" { final-cl-flags $target_platform } else { final-cflags $target_platform })
  let cxxflags = (if $side == "clang-cl" { final-cl-flags $target_platform } else { final-cxxflags $target_platform })
  # Our clang resource dir lives under Library/ (the conda Windows prefix), not at the prefix root where conda-forge's compiler-rt_win puts it; the templates' /lib/clang/<major>/ path would miss clang_rt.builtins-<arch>.lib.
  # Must run BEFORE the @MAJOR_VER@ substitution, which it keys on.
  $text
  | str replace --all "/lib/clang/@MAJOR_VER@/" "/Library/lib/clang/@MAJOR_VER@/"
  | str replace --all "@CHOST@" (chost-for $target_platform)
  | str replace --all "@CFLAGS@" $cflags
  | str replace --all "@CXXFLAGS@" $cxxflags
  | str replace --all "@MAJOR_VER@" $llvm_major
  | builtins-arch-fix $target_platform
}

# UPSTREAM BUG (conda-forge/clang-win-activation, pinned ref): the clang-cl
# .ps1 sets CC=clang.exe / CXX=clang++.exe, while the .bat correctly sets
# clang-cl.exe for both. Shipping that verbatim would give PowerShell users a
# different compiler than cmd users from the same package, so we correct it.
def fix-upstream-ps1-driver [text: string, side: string] {
  if $side != "clang-cl" { return $text }
  $text
  | str replace --all '$Env:CC="clang.exe"' '$Env:CC="clang-cl.exe"'
  | str replace --all '$Env:CXX="clang++.exe"' '$Env:CXX="clang-cl.exe"'
}

def main [side: string, llvm_major: string, target_platform: string] {
  let here = ($env.FILE_PWD)
  let vendor = ($here | path join "vendor" "clang-win-activation")
  # %PREFIX%\etc\conda\activate.d — activation metadata is NOT under Library
  let prefix = $env.PREFIX
  let actd = ($prefix | path join "etc" "conda" "activate.d")
  let deactd = ($prefix | path join "etc" "conda" "deactivate.d")
  mkdir $actd
  mkdir $deactd
  let chost = (chost-for $target_platform)

  # `_y-` sorts after the vs<YEAR> compiler vars; `_z-` (clangxx) after `_y-`
  # (clang) because clangxx reuses CPPFLAGS_USED that clang sets. clang-cl is
  # a standalone driver that intentionally conflicts with the clang/clangxx
  # pair, so it takes `_y-` too and ordering against them never arises.
  let order = (if $side == "clangxx" { "z" } else { "y" })
  # Name shipped files after the PACKAGE (rattler-build sets PKG_NAME), like
  # the linux render script: the nightly lane renames the packages
  # (acpp-clang-nightly_win-64) and the content tests follow the package
  # name, so hardcoded stems would ship files the tests cannot find.
  let pkg = ($env.PKG_NAME? | default $"acpp-($side)_($target_platform)")
  let stem = $"vs($VSYEAR)_($order)-($pkg)"
  # The vendored templates are win-64-named (no arm64-specific variant exists
  # upstream at our pinned ref, and their content beyond @CHOST@/flags/the
  # x86_64 builtins-arch string above is genuinely platform-neutral), so
  # win-arm64 reuses the SAME source templates as win-64.
  let src_stem = $"activate-($side)_win-64"
  # clang-cl covers BOTH languages, so it carries the SYCL delta itself;
  # otherwise the delta rides the CXX side only.
  let carries_delta = ($side in ["clangxx" "clang-cl"])

  for ext in [bat ps1] {
    let f = ($vendor | path join $"($src_stem).($ext)")
    if not ($f | path exists) { continue }
    mut out = (fix-upstream-ps1-driver (render (open --raw $f) $llvm_major $side $target_platform) $side)
    if $carries_delta {
      $out = ($out + (if $ext == "bat" { $ACPP_BAT } else { $ACPP_PS1 }))
    }
    $out | save --force ($actd | path join $"($stem).($ext)")
  }

  # bash side: activate + deactivate, with the delta inside _tc_activation
  # clang-cl has no .sh in the feedstock (cmd/PowerShell only)
  let ash = ($vendor | path join $"($src_stem).sh")
  if ($ash | path exists) {
    mut out = (render (open --raw $ash) $llvm_major $side $target_platform)
    if $side == "clangxx" {
      let cxxflags = (final-cxxflags $target_platform)
      # Insert before the trailing CXXFLAGS entry's line continuation end.
      # BUG FIX (pre-existing, found while adding win-arm64): this matched
      # against the literal "@CXXFLAGS@" placeholder, but render() above has
      # ALREADY substituted it by this point, so the search never matched and
      # the ACPP delta silently never landed in the .sh output on either
      # platform. Match against the real rendered flags instead.
      $out = ($out | str replace $'  "CXXFLAGS,($cxxflags) ${CPPFLAGS_USED}" \
' $'  "CXXFLAGS,($cxxflags) ${CPPFLAGS_USED}" \
($ACPP_SH_ENTRIES)')
    }
    $out | save --force ($actd | path join $"($stem).sh")
  }
  let dsh = ($vendor | path join $"deactivate-($side)_win-64.sh")
  if ($dsh | path exists) {
    mut out = (render (open --raw $dsh) $llvm_major $side $target_platform)
    if $side == "clangxx" {
      $out = ($out + $'
# ---- ACPP DELTA: restore the SYCL environment ---------------------------
_tc_activation deactivate host ($chost) ($chost)- \
  "ACPP_TARGETS," "ACPP_CLANG," "ACPP_CPU_CXX,"
')
    }
    $out | save --force ($deactd | path join $"deactivate-($pkg).sh")
  }

  print $"installed activation for ($side) on ($target_platform): (ls $actd | get name | path basename | str join ', ')"
}
