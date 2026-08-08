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

def render [text: string, llvm_major: string] {
  $text
  | str replace --all "@CHOST@" $CHOST
  | str replace --all "@CFLAGS@" $FINAL_CFLAGS
  | str replace --all "@CXXFLAGS@" $FINAL_CXXFLAGS
  | str replace --all "@MAJOR_VER@" $llvm_major
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

  # `_y-` (clang) must sort after the vs<YEAR> vars; `_z-` (clangxx) after it.
  let order = (if $side == "clang" { "y" } else { "z" })
  let stem = $"vs($VSYEAR)_($order)-acpp-($side)_win-64"
  let src_stem = $"activate-($side)_win-64"

  for ext in [bat ps1] {
    let f = ($vendor | path join $"($src_stem).($ext)")
    if not ($f | path exists) { continue }
    mut out = (render (open --raw $f) $llvm_major)
    # ACPP DELTA rides the CXX side only
    if $side == "clangxx" {
      $out = ($out + (if $ext == "bat" { $ACPP_BAT } else { $ACPP_PS1 }))
    }
    $out | save --force ($actd | path join $"($stem).($ext)")
  }

  # bash side: activate + deactivate, with the delta inside _tc_activation
  let ash = ($vendor | path join $"($src_stem).sh")
  if ($ash | path exists) {
    mut out = (render (open --raw $ash) $llvm_major)
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
    mut out = (render (open --raw $dsh) $llvm_major)
    if $side == "clangxx" {
      $out = ($out + $'
# ---- ACPP DELTA: restore the SYCL environment ---------------------------
_tc_activation deactivate host ($CHOST) ($CHOST)- \
  "ACPP_TARGETS," "ACPP_COMPILER_DIR," "ACPP_CLANG,"
')
    }
    $out | save --force ($deactd | path join $"deactivate-acpp-($side)_win-64.sh")
  }

  print $"installed activation for ($side): (ls $actd | get name | path basename | str join ', ')"
}
