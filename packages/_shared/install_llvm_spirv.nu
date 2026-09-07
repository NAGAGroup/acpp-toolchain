# install_llvm_spirv.nu — the slice of _acpp-llvm-spirv-stage taken by each of
# the four llvm-spirv packages, selected by $PKG_NAME.
#
# LIFTED FROM llvm-spirv-feedstock's `install.sh` / `install.bat` plus the four
# outputs' `files:` lists (vendored in the reference monolith at
# recipe/llvm-spirv/). That feedstock is BOTH forms at once — one install script
# shared by every output, and per-output globs that slice what it produced — so
# this file is one script that branches, which is as close to upstream's shape
# as our stage-and-slicer structure allows. The rename-and-link half of
# upstream's install script has already happened, in build-spirv-stage.nu, since
# it must happen ONCE for all four.
#
# ⚠ THE STAGE HERE IS _spirv-stage, NOT _stage. Two stages exist in this
# workspace and a slicer that read the wrong one would silently ship another
# project's files, so the directory is named explicitly rather than shared with
# carve.nu — which hardcodes _stage and is why these four do not use it.
#
# SCOPE derived from conda-forge's PUBLISHED artifacts at 21.1.4, the newest
# 21-series build of this feedstock:
#   pixi run -e dev nu tools/upstream-paths.nu <name> 21.1.4 <platform>
# libllvmspirv21: ONE path, the versioned library, and no win artifact at all.
# libllvmspirv: the three headers, the unversioned library (a static .lib on
# win), and the pkg-config file. llvm-spirv-21 / llvm-spirv: one binary each.
#
# WHY WIN HAS NO libllvmspirv21: upstream's bld.bat passes no BUILD_SHARED_LIBS
# and CMake defaults it OFF, so the win build produces a STATIC LLVMSPIRVLib.lib
# and there is no versioned shared library to package. build-spirv-stage.nu
# reproduces that split, which is what makes the `skip: win` below correct
# rather than arbitrary.

def is-windows [] { $nu.os-info.name == "windows" }
def is-darwin [] { $nu.os-info.name == "macos" }
def slashes [] { str replace --all '\' '/' }

def place [src: string, layout_root: string, stage: string] {
  let rel = ($src | path relative-to $stage)
  let dst = ($layout_root | slashes | path join $rel)
  mkdir ($dst | path dirname)
  cp -P $src $dst
}

def place-tree [rel: string, layout_root: string, stage: string] {
  let src = ($stage | path join $rel)
  if not ($src | path exists) {
    error make {msg: $"install_llvm_spirv: ($rel) is a required part of this package and is not in the stage at ($src) — the slice has rotted against the stage"}
  }
  let files = (glob $"($src)/**/*" | where {|p| ($p | path type) != "dir" })
  if ($files | is-empty) {
    error make {msg: $"install_llvm_spirv: ($rel) exists in the stage but contains no files"}
  }
  for f in $files { place $f $layout_root $stage }
  $files | length
}

def main [] {
  let layout_root = (if (is-windows) {
    $env.LIBRARY_PREFIX? | default ($env.PREFIX | path join "Library")
  } else {
    $env.PREFIX
  })
  let stage = ($layout_root | path join "_spirv-stage" | slashes)
  if not ($stage | path exists) {
    error make {msg: $"install_llvm_spirv: stage directory ($stage) does not exist — is _acpp-llvm-spirv-stage a host dependency of this package?"}
  }

  let pkg = $env.PKG_NAME
  let major = ($env.ACPP_LLVM_MAJOR? | default "21")
  let maj_min = ($env.ACPP_LLVM_MAJ_MIN? | default "21.1")
  let exe = (if (is-windows) { ".exe" } else { "" })

  # The library in its three spellings. The versioned name is what
  # acpp-libllvmspirv<major> ships; the unversioned one is a symlink onto it on
  # unix, and on win it is the static library itself.
  let versioned_lib = (if (is-darwin) {
    $"lib/libLLVMSPIRVLib.($maj_min).dylib"
  } else {
    $"lib/libLLVMSPIRVLib.so.($maj_min)"
  })
  let plain_lib = (if (is-windows) {
    "lib/LLVMSPIRVLib.lib"
  } else if (is-darwin) {
    "lib/libLLVMSPIRVLib.dylib"
  } else {
    "lib/libLLVMSPIRVLib.so"
  })

  # Each package names exactly what it ships. A path listed here and absent from
  # the stage fails the build: shipping thinner than promised is the same class
  # of defect as shipping a sibling's files.
  let files = (match $pkg {
    "acpp-libllvmspirv21" => [$versioned_lib]
    "acpp-libllvmspirv" => [$plain_lib "lib/pkgconfig/LLVMSPIRVLib.pc"]
    "acpp-llvm-spirv-21" => [$"bin/llvm-spirv-($major)($exe)"]
    "acpp-llvm-spirv" => [$"bin/llvm-spirv($exe)"]
    _ => { error make {msg: $"install_llvm_spirv: PKG_NAME '($pkg)' is not one of the four llvm-spirv packages"} }
  })

  mut placed = 0
  for rel in $files {
    let src = ($stage | path join $rel)
    if not ($src | path exists) {
      error make {msg: $"install_llvm_spirv: ($rel) is a required part of ($pkg) and is not in the stage at ($src) — the slice has rotted against the stage"}
    }
    place $src $layout_root $stage
    $placed = $placed + 1
  }

  # The public headers travel with the unversioned library, as upstream has it:
  # a consumer that links LLVMSPIRVLib gets the headers and the pkg-config file
  # from the same package.
  if $pkg == "acpp-libllvmspirv" {
    $placed = $placed + (place-tree "include/LLVMSPIRVLib" $layout_root $stage)
  }

  print $"install_llvm_spirv: placed ($placed) files for ($pkg)"
}
