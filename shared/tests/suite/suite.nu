#!/usr/bin/env nu
# suite.nu — build and run AdaptiveCpp's OWN test suite (tests/) against the
# INSTALLED naga-acpp channel, through the compiler activation packages.
#
# Runs INSIDE the pixi environment (the `build` or `default` environment
# from pixi.toml), so CONDA_PREFIX and the activation variables (CXX, CC,
# CMAKE_ARGS) are already set by the time this script executes.
#
# Subcommands:
#   nu suite.nu build <name> <targets> [--pstl] [--pcuda]
#   nu suite.nu run <name> <mask> <exe> [...rest]
#   nu suite.nu boost
#
# Pinned so the win-arm64 Boost.Test-from-source build is reproducible
# (conda-forge ships no Boost package for win-arm64 at all). Confirmed at
# hand-off time: boostorg/boost's latest GitHub release is boost-1.92.0,
# and it publishes a boost-1.92.0-cmake.tar.xz asset (checked via
# `http get https://api.github.com/repos/boostorg/boost/releases/latest`).
const BOOST_VERSION = "1.92.0"

# CONDA_PREFIX on unix; CONDA_PREFIX/Library on windows, where conda-forge
# puts headers/libs/cmake files under a Library subdir.
def suite-prefix [] {
  let conda_prefix = ($env.CONDA_PREFIX? | default "")
  if $conda_prefix == "" {
    error make {msg: "suite.nu: CONDA_PREFIX is not set — run this inside the pixi environment (e.g. `pixi run -e default nu suite.nu ...`)"}
  }
  if $nu.os-info.name == "windows" {
    $conda_prefix | path join "Library"
  } else {
    $conda_prefix
  }
}

def suite-build-dir [name: string] {
  $env.FILE_PWD | path join "build" $name
}

# ── build ────────────────────────────────────────────────────────────────
def "main build" [
  name: string      # build/<name> — one dir per ACPP_TARGETS configuration
  targets: string   # -DACPP_TARGETS value, e.g. "generic" or "omp;cuda:sm_70"
  --pstl            # also configure+build pstl_tests (WITH_PSTL_TESTS=ON)
  --pcuda           # also configure+build pcuda_tests (WITH_PCUDA_TESTS=ON)
] {
  let acpp_src = ($env.ACPP_SRC? | default "")
  if $acpp_src == "" {
    error make {msg: "suite.nu build: ACPP_SRC is not set — point it at the acpp-fork checkout (CI checks the fork out there)"}
  }
  let src = ($acpp_src | path join "tests")
  let dir = (suite-build-dir $name)
  mkdir $dir

  let prefix = (suite-prefix)

  let cxx = ($env.CXX? | default "")
  let cc = ($env.CC? | default "")
  if $cxx == "" or $cc == "" {
    error make {msg: "suite.nu build: CXX/CC are not set — the naga-acpp-clangxx_* activation package must be installed and activated in this environment"}
  }

  # AdaptiveCpp_DIR must be the directory CONTAINING AdaptiveCppConfig.cmake
  # (find_package(AdaptiveCpp) semantics) — its exact subpath under prefix
  # varies by platform, so glob rather than hardcode it.
  let cfgs = (glob ($prefix | path join "**" "AdaptiveCppConfig.cmake"))
  if ($cfgs | is-empty) {
    error make {msg: $"suite.nu build: AdaptiveCppConfig.cmake not found anywhere under ($prefix) — is naga-acpp installed in this environment?"}
  }
  let acpp_dir = ($cfgs | first | path dirname)

  mut args = [
    "-G" "Ninja"
    "-S" $src
    "-B" $dir
    "-DCMAKE_BUILD_TYPE=Release"
    $"-DACPP_TARGETS=($targets)"
    $"-DCMAKE_CXX_COMPILER=($cxx)"
    $"-DCMAKE_C_COMPILER=($cc)"
    $"-DAdaptiveCpp_DIR=($acpp_dir)"
    # tests/CMakeLists.txt shells out to `brew list libomp` on APPLE when
    # OpenMP_ROOT/OMP_ROOT are undefined — pointing it at prefix avoids that.
    $"-DOpenMP_ROOT=($prefix)"
  ]

  # CMAKE_PREFIX_PATH: prefix, plus SUITE_BOOST_PREFIX (win-arm64's
  # from-source Boost.Test install, set by `main boost`) when present.
  let boost_prefix = ($env.SUITE_BOOST_PREFIX? | default "")
  let cmake_prefix_path = (if $boost_prefix == "" { $prefix } else { $"($prefix);($boost_prefix)" })
  $args = ($args | append $"-DCMAKE_PREFIX_PATH=($cmake_prefix_path)")

  # Only tests/compiler/'s lit-based check-* targets need LLVM_DIR, and this
  # suite never builds/runs those — but pass it through when it happens to
  # exist on the prefix, at no cost.
  let llvm_dir = ($prefix | path join "lib" "cmake" "llvm")
  if ($llvm_dir | path exists) {
    $args = ($args | append $"-DLLVM_DIR=($llvm_dir)")
  }

  if $pstl { $args = ($args | append "-DWITH_PSTL_TESTS=ON") }
  if $pcuda { $args = ($args | append "-DWITH_PCUDA_TESTS=ON") }

  # The conda contract: CMAKE_ARGS carries sysroot/deployment-target/ar-
  # ranlib flags as a single space-separated string, same as any conda-forge
  # build script.
  let extra = ($env.CMAKE_ARGS? | default "" | split row " " | where {|w| $w != "" })
  $args = ($args | append $extra)

  print $"cmake ($args | str join ' ')"
  ^cmake ...$args

  mut targets_list = ["sycl_tests" "rt_tests"]
  if $pstl { $targets_list = ($targets_list | append "pstl_tests") }
  if $pcuda { $targets_list = ($targets_list | append "pcuda_tests") }

  mut build_args = ["--build" $dir]
  for t in $targets_list {
    $build_args = ($build_args | append ["--target" $t])
  }
  # -k 0 (keep going, unlimited failures) surfaces every compile error in
  # one run instead of stopping at the first.
  $build_args = ($build_args | append ["--" "-k" "0"])

  print $"cmake ($build_args | str join ' ')"
  ^cmake ...$build_args
}

# ── run ──────────────────────────────────────────────────────────────────
def "main run" [
  name: string       # same build/<name> used in `main build`
  mask: string        # ACPP_VISIBILITY_MASK, e.g. "omp", "cuda", "ocl"
  exe: string          # executable name, without extension
  ...rest: string      # extra args forwarded to the executable
] {
  let dir = (suite-build-dir $name)
  if not ($dir | path exists) {
    error make {msg: $"suite.nu run: build dir ($dir) does not exist — run `nu suite.nu build ($name) ...` first"}
  }
  let is_windows = ($nu.os-info.name == "windows")
  let exe_name = (if $is_windows { $"($exe).exe" } else { $exe })

  cd $dir
  with-env {ACPP_VISIBILITY_MASK: $mask} {
    if $is_windows {
      let boost_prefix = ($env.SUITE_BOOST_PREFIX? | default "")
      mut prepend = [$dir]
      if $boost_prefix != "" {
        $prepend = ([($boost_prefix | path join "bin")] | append $prepend)
      }
      with-env {PATH: ($prepend | append $env.PATH)} {
        ^$"./($exe_name)" ...$rest
      }
    } else {
      ^$"./($exe_name)" ...$rest
    }
  }

  if $env.LAST_EXIT_CODE != 0 {
    exit $env.LAST_EXIT_CODE
  }
}

# ── boost (win-arm64 only) ───────────────────────────────────────────────
def "main boost" [] {
  let prefix = ($env.FILE_PWD | path join "build" "boost-prefix")
  if (($prefix | path join "lib" "cmake") | path exists) {
    print $"suite.nu boost: ($prefix)/lib/cmake already exists, skipping build"
    print $"SUITE_BOOST_PREFIX=($prefix)"
    return
  }

  let cxx = ($env.CXX? | default "")
  let cc = ($env.CC? | default "")
  if $cxx == "" or $cc == "" {
    error make {msg: "suite.nu boost: CXX/CC are not set — the naga-acpp-clangxx_win-arm64 activation package must be installed and activated in this environment"}
  }

  let work = ($env.FILE_PWD | path join "build" "boost-src")
  mkdir $work
  let asset = $"boost-($BOOST_VERSION)-cmake.tar.xz"
  let url = $"https://github.com/boostorg/boost/releases/download/boost-($BOOST_VERSION)/($asset)"
  let tarball = ($work | path join $asset)

  print $"suite.nu boost: downloading ($url)"
  http get --raw $url | save --force $tarball

  print $"suite.nu boost: extracting ($tarball)"
  ^tar -xf $tarball --directory $work

  let src = ($work | path join $"boost-($BOOST_VERSION)")
  let dir = ($env.FILE_PWD | path join "build" "boost-build")

  let args = [
    "-G" "Ninja"
    "-S" $src
    "-B" $dir
    "-DBOOST_INCLUDE_LIBRARIES=test"
    "-DBUILD_SHARED_LIBS=ON"
    "-DCMAKE_BUILD_TYPE=Release"
    $"-DCMAKE_CXX_COMPILER=($cxx)"
    $"-DCMAKE_C_COMPILER=($cc)"
    $"-DCMAKE_INSTALL_PREFIX=($prefix)"
  ]
  print $"cmake ($args | str join ' ')"
  ^cmake ...$args

  print $"cmake --build ($dir)"
  ^cmake --build $dir

  print $"cmake --install ($dir)"
  ^cmake --install $dir

  print $"SUITE_BOOST_PREFIX=($prefix)"
}

def main [] {
  print "usage: nu suite.nu {build <name> <targets> [--pstl] [--pcuda] | run <name> <mask> <exe> [...rest] | boost}"
}
