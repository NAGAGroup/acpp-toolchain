# install_openmp.nu — acpp-llvm-openmp's slice of the stage.
#
# LIFTED FROM openmp-feedstock's `install_pkg.sh` / `install_pkg.bat` (vendored
# in the reference monolith at recipe/openmp/). openmp is one of the feedstocks
# that does NOT slice with globs: it is a single-output recipe whose package is
# "whatever the build installed", produced by `cmake --install .` plus fixups.
# The script IS the slice, so it stays a script.
#
# THE STRUCTURAL CHANGE, and it is forced: `cmake --install .` re-installs from
# a BUILD TREE. A slicer has no build tree — it has `_acpp-stage` as a host
# dependency, already installed under <layout_root>/_stage. So the install
# becomes a copy, and "whatever the build installed" has to be stated, because
# our stage is a UNION build (llvm + clang + clang-tools-extra + lld + lldb +
# openmp + compiler-rt + AdaptiveCpp) and openmp's share of it is not
# recoverable from the tree alone.
#
# SCOPE is therefore derived from conda-forge's PUBLISHED llvm-openmp-21.1.8
# artifact rather than from upstream's install step. Re-read the contract with:
#   pixi run -e dev nu tools/upstream-paths.nu llvm-openmp 21.1.8 <platform>
# 11 paths on linux-64, 6 on osx-arm64, 10 on win-64.
#
# ONE PATH FROM THAT SET IS DELIBERATELY NOT SHIPPED. The win artifact carries
# Library/lib/clang/{18,19,20}/include/omp.h: stand-alone openmp does not land
# omp.h on clang's default search path, and on win there is no symlink to fix
# that with, so install_pkg.bat copies the header into the resource dir of
# several likely clang versions. Upstream's own comment bounds that loop at 20
# because clang 21 and later do the copy themselves. We ship exactly one clang,
# 21, and a consumer cannot reach conda-forge's under strict channel priority,
# so the loop has no reachable target. It is also uncopyable here: those three
# directories do not exist in the stage, so reproducing them would mean
# inventing files rather than slicing.
#
# TWO FIXUPS ARE ALREADY DONE FOR US. `install_pkg.sh` deletes the libgomp
# aliases and renames libarcher.so to libarcher.so.bak "so that it doesn't
# interfere"; `_acpp-stage`'s build-stage.nu already replays both (see
# openmp-install-fixups). So this script neither deletes nor renames — it names
# `libarcher.so.bak` directly, which is also the path the artifact ships.

def is-windows [] { $nu.os-info.name == "windows" }
def is-darwin [] { $nu.os-info.name == "macos" }
def slashes [] { str replace --all '\' '/' }

def place [src: string, layout_root: string, stage: string] {
  let rel = ($src | path relative-to $stage)
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
    error make {msg: $"install_openmp: stage directory ($stage) does not exist — is _acpp-stage a host dependency of this package?"}
  }
  let ext = (if (is-darwin) { ".dylib" } else { ".so" })

  # REQUIRED — the OpenMP runtime itself and the headers a consumer compiles
  # against. libiomp5 is LLVM's Intel-compatible alias, installed by
  # LIBOMP_INSTALL_ALIASES, which defaults ON and which our stage does not
  # disable. A missing entry here fails the build.
  let required = (if (is-windows) {
    ["bin/libomp.dll" "lib/libomp.lib" "lib/libiomp5md.lib"
     "include/omp.h" "include/ompx.h"]
  } else {
    [$"lib/libomp($ext)" $"lib/libiomp5($ext)" "include/omp.h" "include/ompx.h"]
  })

  # OPTIONAL — every remaining path the upstream artifact carries. These are
  # conditional on cmake options rather than on platform, and our stage does not
  # configure openmp the way openmp-feedstock does: upstream builds it
  # standalone with LLVM_ENABLE_RUNTIMES=openmp from ../runtimes, our stage
  # builds it as an LLVM_ENABLE_PROJECTS entry inside the full tree, and sets
  # OPENMP_ENABLE_LIBOMPTARGET=OFF (build-stage.nu). The OMPT headers, the
  # archer TSan tool and the OMPD library all hang off options that difference
  # can flip, and none of them is verifiable without a build.
  #
  # So they are listed, not guessed at, and the build LOGS which ones were
  # absent. That log line is the measurement this list should be tightened
  # against on the first real build — not a licence to ship silently thinner.
  let optional = (if (is-windows) {
    ["include/omp_lib.h"]
  } else if (is-darwin) {
    ["include/omp-tools.h" "include/ompt.h"]
  } else {
    ["include/omp-tools.h" "include/ompt.h" "include/ompt-multiplex.h"
     "lib/libarcher.so.bak" "lib/libarcher_static.a" "lib/libompd.so"
     "lib/cmake/openmp/FindOpenMPTarget.cmake"]
  })

  mut placed = 0
  for rel in $required {
    let src = ($stage | path join $rel)
    if not ($src | path exists) {
      error make {msg: $"install_openmp: ($rel) is a required part of this package and is not in the stage at ($src) — the slice has rotted against the stage"}
    }
    place $src $layout_root $stage
    $placed = $placed + 1
  }

  mut missing = []
  for rel in $optional {
    let src = ($stage | path join $rel)
    if ($src | path exists) {
      place $src $layout_root $stage
      $placed = $placed + 1
    } else {
      $missing = ($missing | append $rel)
    }
  }

  # libiomp5md.dll is NOT copied from the stage. LLVM installs it as a full COPY
  # of libomp.dll, and a process that loads both then reports that a second
  # OpenMP runtime is present even though the bytes are identical. Upstream's
  # install_pkg.bat replaces the copy with a forwarder DLL; the same is done
  # here, against our own prefix, which is why create-forwarder-dll is a build
  # dependency on win.
  if (is-windows) {
    let bin = ($layout_root | slashes | path join "bin")
    ^create-forwarder-dll ($bin | path join "libomp.dll") ($bin | path join "libiomp5md.dll") --no-temp-dir
    let fwd = ($bin | path join "libiomp5md.dll")
    if not ($fwd | path exists) {
      error make {msg: "install_openmp: create-forwarder-dll did not produce libiomp5md.dll"}
    }
    $placed = $placed + 1
  }

  if ($missing | is-empty) {
    print "install_openmp: every optional path was present"
  } else {
    print $"install_openmp: OPTIONAL PATHS ABSENT FROM THE STAGE — ($missing | str join ', ')"
  }
  print $"install_openmp: placed ($placed) files"
}
