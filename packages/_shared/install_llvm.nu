# install_llvm.nu — the llvmdev family's slice, branching on $PKG_NAME.
#
# LIFTED FROM llvmdev-feedstock's `recipe/install_llvm.sh` / `install_llvm.bat`
# (vendored verbatim in the reference monolith at recipe/llvmdev/). llvmdev is
# one of the four feedstocks that does NOT slice with globs: one script installs
# to a temporary prefix and then moves a different subset per package name. The
# script IS the slice, so it is preserved as a script, with one arm per name,
# rather than translated into glob lists — translating it would be exactly the
# unverifiable judgement this rework exists to remove.
#
# THE ONE STRUCTURAL CHANGE, and it is forced: every upstream arm opens with
# `cmake --install ./build --prefix=./temp_prefix`, re-installing from a BUILD
# TREE. A slicer has no build tree — it has `_acpp-stage` as a host dependency,
# already installed under <layout_root>/_stage. So **_stage IS temp_prefix**,
# and everything after that line is lifted operation for operation.
#
# WHY `llvmdev` CAN SAY "EVERYTHING ELSE". Upstream declares `libllvm<major>`
# and `llvm-tools` as HOST dependencies of `llvmdev`, so their files are already
# in the prefix when llvmdev builds and a conda package is the file DIFF of its
# build — the remainder is what is left. We keep those host deps, so the same
# subtraction happens for the same reason. The `if already present, skip` test
# below is that mechanism made explicit rather than a second policy.
#
# NO VERSION PARSING. Upstream computes MAJOR_VER/SOVER_EXT/MAJOR_EXT by
# splitting PKG_VERSION. Inherited version-parsing is the class of bug that put
# a YEAR into a clang resource-dir path, so the values arrive from the recipe as
# ACPP_LLVM_MAJOR / ACPP_LLVM_MAJ_MIN. The rc/dev suffix branches upstream
# carries do not apply: we build tagged releases only.

def is-windows [] { $nu.os-info.name == "windows" }
def is-darwin [] { $nu.os-info.name == "macos" }
def slashes [] { str replace --all '\' '/' }
def shlib-ext [] { if (is-darwin) { ".dylib" } else { ".so" } }

# Copy one stage path to the same relative path at the top of the layout root.
# Identical relative depth is what keeps $ORIGIN/../lib and the clang driver's
# resource-dir lookup valid. `cp -P` preserves symlinks: `-p` is --progress and
# cp DEREFERENCES by default, which turns an LLVM symlink farm into gigabytes.
def place [src: string, layout_root: string, stage: string, dest_rel?: string] {
  let rel = (if $dest_rel == null { ($src | path relative-to $stage) } else { $dest_rel })
  let dst = ($layout_root | slashes | path join $rel)
  mkdir ($dst | path dirname)
  cp -P $src $dst
}

def main [] {
  let layout_root = (if (is-windows) {
    $env.LIBRARY_PREFIX? | default ($env.PREFIX | path join "Library")
  } else {
    $env.PREFIX
  })
  let stage = ($layout_root | path join "_stage" | slashes)
  if not ($stage | path exists) {
    error make {msg: $"install_llvm: stage directory ($stage) does not exist — is _acpp-stage a host dependency of this package?"}
  }

  let name = ($env.PKG_NAME? | default "")
  let major = $env.ACPP_LLVM_MAJOR
  let sover = $env.ACPP_LLVM_MAJ_MIN
  let ext = (shlib-ext)
  mut placed = 0

  if ($name | str starts-with "acpp-libllvm-c") {
    # -- upstream arm 1: only libLLVM-C --
    if (is-windows) {
      place $"($stage)/bin/LLVM-C.dll" $layout_root $stage
      place $"($stage)/lib/LLVM-C.lib" $layout_root $stage
      $placed = 2
    } else {
      for f in (glob $"($stage)/lib/libLLVM-C($sover)($ext)") {
        place $f $layout_root $stage
        $placed = $placed + 1
      }
    }
  } else if ($name | str starts-with "acpp-libllvm") {
    # -- upstream arm 2: all other shared libraries --
    # `|| true` upstream: exactly one of the two versioned patterns matches on a
    # given platform, so an empty match is expected, not a defect.
    let pats = [
      $"($stage)/lib/libLLVM-($major)($ext)"
      $"($stage)/lib/lib*.so.($sover)"
      $"($stage)/lib/lib*.($sover).dylib"
    ]
    for p in $pats {
      for f in (glob $p) {
        place $f $layout_root $stage
        $placed = $placed + 1
      }
    }
  } else if $name == $"acpp-llvm-tools-($major)" {
    # -- upstream arm 3: every bin/* copied WITH a -<major> suffix, except
    #    llvm-config-<major>, which belongs to llvmdev --
    for f in (glob $"($stage)/bin/*") {
      if (($f | path type) == "dir") { continue }
      let base = ($f | path basename)
      if $base == $"llvm-config-($major)" { continue }
      # The stage already carries the versioned clang drivers (the clangdev
      # install fixups made them); re-suffixing those would produce the
      # "doubly versioned" binaries upstream's own clang-tools test forbids.
      if ($base | str ends-with $"-($major)") { continue }
      place $f $layout_root $stage $"bin/($base)-($major)"
      $placed = $placed + 1
    }
    let cfg = ($layout_root | slashes | path join $"bin/llvm-config-($major)")
    if ($cfg | path exists) { rm -f $cfg }
  } else if $name == "acpp-llvm-tools" {
    if (is-windows) {
      # -- upstream arm 4, win: the executables and share/, no symlinks --
      for f in (glob $"($stage)/bin/*.exe") {
        place $f $layout_root $stage
        $placed = $placed + 1
      }
      for f in (glob $"($stage)/share/*") {
        if (($f | path type) == "dir") { continue }
        place $f $layout_root $stage
        $placed = $placed + 1
      }
      let cfg = ($layout_root | slashes | path join "bin/llvm-config.exe")
      if ($cfg | path exists) { rm -f $cfg }
    } else {
      # -- upstream arm 4, unix: a symlink farm onto llvm-tools-<major>, plus
      #    share/*, minus llvm-config --
      for f in (glob $"($stage)/bin/*") {
        if (($f | path type) == "dir") { continue }
        let base = ($f | path basename)
        if ($base | str ends-with $"-($major)") { continue }
        let dst = ($layout_root | slashes | path join $"bin/($base)")
        mkdir ($dst | path dirname)
        ^ln -sf ($layout_root | slashes | path join $"bin/($base)-($major)") $dst
        $placed = $placed + 1
      }
      for f in (glob $"($stage)/share/*") {
        if (($f | path type) == "dir") { continue }
        place $f $layout_root $stage
        $placed = $placed + 1
      }
      let cfg = ($layout_root | slashes | path join "bin/llvm-config")
      if ($cfg | path exists) { rm -f $cfg }
    }
  } else {
    # -- upstream arm 5, llvmdev: install everything else. The host deps above
    #    have already put their files in the prefix, so those are not new. --
    for f in (glob $"($stage)/**/*") {
      if (($f | path type) == "dir") { continue }
      let rel = ($f | path relative-to $stage)
      let dst = ($layout_root | slashes | path join $rel)
      if ($dst | path exists) { continue }
      mkdir ($dst | path dirname)
      cp -P $f $dst
      $placed = $placed + 1
    }
  }

  if $placed == 0 {
    error make {msg: $"install_llvm: the ($name) arm placed no files — the slice has rotted against the stage"}
  }
  print $"install_llvm: ($name) placed ($placed) files"
}
