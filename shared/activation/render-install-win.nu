#!/usr/bin/env nu
# render-install-win.nu — render + install the acpp compiler activation scripts
# for win-64 from the VENDORED conda-forge clang-win-activation templates
# (pinned ref in vendor/clang-win-activation/PINNED_REF).
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
# Usage: nu render-install-win.nu {clang|clangxx} <llvm_major>

# ---- canonical values (vendor/conda_build_config.yaml, newest zip entry) ----
const VSYEAR = "2022"
const CHOST = "x86_64-pc-windows-msvc"
# FINAL_* are the ctng linux64 flags minus -fPIC/-fno-plt (see vendored cbc)
const FINAL_CFLAGS = "-march=nocona -mtune=haswell -ftree-vectorize -fstack-protector-strong -O2 -ffunction-sections -pipe"
const FINAL_CXXFLAGS = "-fvisibility-inlines-hidden -std=c++17 -fmessage-length=0 -march=nocona -mtune=haswell -ftree-vectorize -fstack-protector-strong -O2 -ffunction-sections -pipe"
# clang-cl takes MSVC-style flags; both @CFLAGS@ and @CXXFLAGS@ render to this.
const FINAL_CL_FLAGS = "/Oi /O2 /GS /Gy /MD -march=nocona -mtune=haswell -fuse-ld=lld"

# ACPP DELTA — the SYCL environment, added on the CXX side only (mirrors the
# linux port). ACPP_TARGETS respects a pre-set value; generic SSCP is the only
# compiled flow, so one binary JITs per device. Paths use the conda Windows
# layout (%CONDA_PREFIX%\Library).
const ACPP_BAT = '
REM ---- ACPP DELTA: SYCL environment -------------------------------------
if not defined ACPP_TARGETS set "ACPP_TARGETS=generic"
set "ACPP_COMPILER_DIR=%CONDA_PREFIX%\Library"
set "ACPP_CLANG=%CONDA_PREFIX%\Library\bin\clang++.exe"
'

const ACPP_PS1 = '
# ---- ACPP DELTA: SYCL environment ---------------------------------------
if (-not $Env:ACPP_TARGETS) { $Env:ACPP_TARGETS = "generic" }
$Env:ACPP_COMPILER_DIR = "$Env:CONDA_PREFIX\Library"
$Env:ACPP_CLANG = "$Env:CONDA_PREFIX\Library\bin\clang++.exe"
'

# For the .sh side the delta rides the existing _tc_activation call, so
# deactivation symmetry comes for free (same as linux).
const ACPP_SH_ENTRIES = '  "ACPP_TARGETS,${ACPP_TARGETS:-generic}" \
  "ACPP_COMPILER_DIR,${CONDA_PREFIX}/Library" \
  "ACPP_CLANG,${CONDA_PREFIX}/Library/bin/clang++.exe" \
'

def render [text: string, llvm_major: string, side: string] {
  # clang-cl is a single driver for both languages, so both flag slots take
  # the MSVC-style flag set.
  let cflags = (if $side == "clang-cl" { $FINAL_CL_FLAGS } else { $FINAL_CFLAGS })
  let cxxflags = (if $side == "clang-cl" { $FINAL_CL_FLAGS } else { $FINAL_CXXFLAGS })
  $text
  | str replace --all "@CHOST@" $CHOST
  | str replace --all "@CFLAGS@" $cflags
  | str replace --all "@CXXFLAGS@" $cxxflags
  | str replace --all "@MAJOR_VER@" $llvm_major
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

def main [side: string, llvm_major: string] {
  let here = ($env.FILE_PWD)
  let vendor = ($here | path join "vendor" "clang-win-activation")
  # %PREFIX%\etc\conda\activate.d — activation metadata is NOT under Library
  let prefix = $env.PREFIX
  let actd = ($prefix | path join "etc" "conda" "activate.d")
  let deactd = ($prefix | path join "etc" "conda" "deactivate.d")
  mkdir $actd
  mkdir $deactd

  # `_y-` sorts after the vs<YEAR> compiler vars; `_z-` (clangxx) after `_y-`
  # (clang) because clangxx reuses CPPFLAGS_USED that clang sets. clang-cl is
  # a standalone driver that intentionally conflicts with the clang/clangxx
  # pair, so it takes `_y-` too and ordering against them never arises.
  let order = (if $side == "clangxx" { "z" } else { "y" })
  # Name shipped files after the PACKAGE (rattler-build sets PKG_NAME), like
  # the linux render script: the nightly lane renames the packages
  # (acpp-clang-nightly_win-64) and the content tests follow the package
  # name, so hardcoded stems would ship files the tests cannot find.
  let pkg = ($env.PKG_NAME? | default $"acpp-($side)_win-64")
  let stem = $"vs($VSYEAR)_($order)-($pkg)"
  let src_stem = $"activate-($side)_win-64"
  # clang-cl covers BOTH languages, so it carries the SYCL delta itself;
  # otherwise the delta rides the CXX side only.
  let carries_delta = ($side in ["clangxx" "clang-cl"])

  for ext in [bat ps1] {
    let f = ($vendor | path join $"($src_stem).($ext)")
    if not ($f | path exists) { continue }
    mut out = (fix-upstream-ps1-driver (render (open --raw $f) $llvm_major $side) $side)
    if $carries_delta {
      $out = ($out + (if $ext == "bat" { $ACPP_BAT } else { $ACPP_PS1 }))
    }
    $out | save --force ($actd | path join $"($stem).($ext)")
  }

  # bash side: activate + deactivate, with the delta inside _tc_activation
  # clang-cl has no .sh in the feedstock (cmd/PowerShell only)
  let ash = ($vendor | path join $"($src_stem).sh")
  if ($ash | path exists) {
    mut out = (render (open --raw $ash) $llvm_major $side)
    if $side == "clangxx" {
      # Insert before the trailing CXXFLAGS entry's line continuation end
      $out = ($out | str replace $'  "CXXFLAGS,@CXXFLAGS@ ${CPPFLAGS_USED}" \
' $'  "CXXFLAGS,($FINAL_CXXFLAGS) ${CPPFLAGS_USED}" \
($ACPP_SH_ENTRIES)')
    }
    $out | save --force ($actd | path join $"($stem).sh")
  }
  let dsh = ($vendor | path join $"deactivate-($side)_win-64.sh")
  if ($dsh | path exists) {
    mut out = (render (open --raw $dsh) $llvm_major $side)
    if $side == "clangxx" {
      $out = ($out + $'
# ---- ACPP DELTA: restore the SYCL environment ---------------------------
_tc_activation deactivate host ($CHOST) ($CHOST)- \
  "ACPP_TARGETS," "ACPP_COMPILER_DIR," "ACPP_CLANG,"
')
    }
    $out | save --force ($deactd | path join $"deactivate-($pkg).sh")
  }

  print $"installed activation for ($side): (ls $actd | get name | path basename | str join ', ')"
}
