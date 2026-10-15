#!/usr/bin/env nu
# suite.nu — package, install and run AdaptiveCpp's OWN test suite (tests/)
# against the INSTALLED naga-acpp channel.
#
# The suite is BUILT as one pixi source package (pkg-generic/, the generic SSCP flow): `package`
# copies the fork's tests/ in and runs `pixi publish --target-dir`, which
# compiles it against the toolchain (compiler activation packages, run_exports,
# the exact naga-acpp-llvm lane pin) and leaves a .conda under pkgs/<name>/.
# `install` adds those .conda files to the `suite` feature and installs the
# per-backend run environments (run-omp, run-ocl, run-cuda); `run` executes an
# installed test binary in the environment that matches the backend mask.
#
# Subcommands:
#   nu suite.nu package generic generic         (needs ACPP_SRC)
#   nu suite.nu install
#   nu suite.nu run <name> <mask> <exe> [...rest]
#   nu suite.nu info
#   nu suite.nu boost
#
# Pinned so the win-arm64 Boost.Test-from-source build is reproducible
# (conda-forge ships no Boost package for win-arm64 at all). Confirmed at
# hand-off time: boostorg/boost's latest GitHub release is boost-1.92.0,
# and it publishes a boost-1.92.0-cmake.tar.xz asset (checked via
# `http get https://api.github.com/repos/boostorg/boost/releases/latest`).
# pkg-*/CMakeLists.txt fetches the same release for win-arm64.
const BOOST_VERSION = "1.92.0"

# The suite workspace manifest.
def suite-manifest [] {
  $env.FILE_PWD | path join "pixi.toml"
}

# The pixi platform name of this machine.
def current-platform [] {
  let os = $nu.os-info.name
  let arch = $nu.os-info.arch
  match [$os $arch] {
    ["linux" "x86_64"] => "linux-64"
    ["linux" "aarch64"] => "linux-aarch64"
    ["windows" "x86_64"] => "win-64"
    ["windows" "aarch64"] => "win-arm64"
    ["macos" "aarch64"] => "osx-arm64"
    _ => { error make {msg: $"suite.nu: unsupported platform ($os)/($arch)"} }
  }
}

# The run environments that exist on this platform (see pixi.toml: run-ocl is
# linux-64 only, run-cuda and run-rocm only carry runtimes where CI tests them).
def run-envs [] {
  let p = (current-platform)
  mut envs = ["run-omp"]
  if $p == "linux-64" { $envs = ($envs | append "run-ocl") }
  if $p in ["linux-64" "linux-aarch64" "win-64"] { $envs = ($envs | append "run-cuda") }
  if $p in ["linux-64" "win-64"] { $envs = ($envs | append "run-rocm") }
  $envs
}

# ── package ──────────────────────────────────────────────────────────────
def "main package" [
  name: string      # pkg-<name>: only generic exists
  targets: string   # the ACPP_TARGETS of that package (fixed in its pixi.toml): generic
] {
  if $name != "generic" or $targets != "generic" {
    error make {msg: $"suite.nu package: only the generic package exists \(got name '($name)', targets '($targets)'\) — the omp AOT flow is not tested"}
  }
  let acpp_src = ($env.ACPP_SRC? | default "")
  if $acpp_src == "" {
    error make {msg: "suite.nu package: ACPP_SRC is not set — point it at the acpp-fork checkout (CI checks the fork out there)"}
  }
  let pkg = ($env.FILE_PWD | path join $"pkg-($name)")
  if not ($pkg | path join "pixi.toml" | path exists) {
    error make {msg: $"suite.nu package: ($pkg)/pixi.toml does not exist"}
  }

  # Replace the old copy: stale files must not survive into the package.
  let dest = ($pkg | path join "tests")
  rm -rf $dest
  cp -r ($acpp_src | path join "tests") $dest

  let out = ($env.FILE_PWD | path join "pkgs" $name)
  rm -rf $out
  mkdir $out

  cd $env.FILE_PWD
  print $"pixi publish --path ($pkg) --target-dir ($out)"
  ^pixi publish --path $pkg --target-dir $out

  let pattern = ($out | path join "**" "*.conda" | str replace --all '\' '/')
  let built = (glob $pattern)
  if ($built | is-empty) {
    error make {msg: $"suite.nu package: pixi publish left no .conda under ($out)"}
  }
  for b in $built { print $"suite.nu package: built ($b)" }
}

# ── install ──────────────────────────────────────────────────────────────
def "main install" [] {
  let manifest = (suite-manifest)
  # One package: the generic test package.
  let pattern = ($env.FILE_PWD | path join "pkgs" "generic" "**" "*.conda" | str replace --all '\' '/')
  let pkgs = (glob $pattern)
  if ($pkgs | is-empty) {
    error make {msg: $"suite.nu install: no .conda under ($env.FILE_PWD)/pkgs/generic — run `nu suite.nu package generic generic` first"}
  }
  if ($pkgs | length) != 1 {
    error make {msg: $"suite.nu install: expected exactly one .conda under pkgs/generic, found ($pkgs | length): ($pkgs | str join ', ')"}
  }
  let p = ($pkgs | first)
  print $"pixi add --feature suite ($p)"
  ^pixi add --manifest-path $manifest --feature suite --no-install $p
  if $env.LAST_EXIT_CODE != 0 {
    error make {msg: $"suite.nu install: pixi add --feature suite ($p) failed with exit code ($env.LAST_EXIT_CODE)"}
  }
  for e in (run-envs) {
    print $"pixi install -e ($e)"
    ^pixi install --manifest-path $manifest -e $e
    if $env.LAST_EXIT_CODE != 0 {
      error make {msg: $"suite.nu install: pixi install -e ($e) failed with exit code ($env.LAST_EXIT_CODE)"}
    }
  }
}

# ── run ──────────────────────────────────────────────────────────────────
def "main run" [
  name: string       # generic: which test package
  mask: string        # ACPP_VISIBILITY_MASK, e.g. "omp", "cuda", "ocl", "omp;cuda"
  exe: string          # test executable: sycl_tests, rt_tests, pstl_tests, pcuda_tests
  ...rest: string      # extra args forwarded to the executable
] {
  # The environment that has the runtime for the mask.
  let run_env = (if ($mask | str contains "cuda") {
    "run-cuda"
  } else if ($mask | str contains "ocl") {
    "run-ocl"
  } else if $mask in ["omp" "metal"] {
    "run-omp"
  } else {
    error make {msg: $"suite.nu run: no run environment for visibility mask '($mask)' (omp/metal -> run-omp, ocl -> run-ocl, *cuda* -> run-cuda)"}
  })

  # Name every test as it starts, so a hang or crash is attributable from the log alone.
  let has_log_level = ($rest | any {|a| $a | str starts-with "--log_level"})
  let exe_args = (if $has_log_level { $rest } else { $rest | append "--log_level=test_suite" })

  let code = (with-env {ACPP_VISIBILITY_MASK: $mask} {
    ^pixi run -e $run_env --manifest-path (suite-manifest) $"acpp-suite-($name)-($exe)" ...$exe_args
    $env.LAST_EXIT_CODE
  })
  if $code != 0 {
    exit $code
  }
}

# ── hip-load-check ───────────────────────────────────────────────────────
# The HIP plugin must LOAD (its libraries and symbols resolve) even without a GPU: run acpp-info in
# run-rocm and fail if the backend loader reports it could not load the HIP backend library.
def "main hip-load-check" [] {
  let log_dir = ($env.FILE_PWD | path join "build")
  mkdir $log_dir
  let log = ($log_dir | path join "hip-load-check.log")
  ^pixi run -e run-rocm --manifest-path (suite-manifest) acpp-info o+e>| tee { save -f $log } | print
  let bad = (open --raw $log | ansi strip | lines | where {|l| ($l | str contains "Could not load library") and ($l | str contains "backend-hip")})
  if ($bad | is-not-empty) {
    print "hip-load-check: FAIL — the HIP backend library did not load:"
    for l in $bad { print $"  ($l)" }
    exit 1
  }
  print "hip-load-check: OK — no 'Could not load library' for backend-hip"
}

# ── info ─────────────────────────────────────────────────────────────────
def "main info" [] {
  mut worst = 0
  for e in (run-envs) {
    print $"===== acpp-info -l in ($e)"
    # `acpp-info` is the pixi task (cmd = "acpp-info -l"), so no extra -l here.
    ^pixi run -e $e --manifest-path (suite-manifest) acpp-info
    if $env.LAST_EXIT_CODE != 0 { $worst = $env.LAST_EXIT_CODE }
  }
  if $worst != 0 { exit $worst }
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

  let jobs = (sys cpu | length)
  print $"suite.nu: building with ($jobs) parallel jobs"
  print $"cmake --build ($dir) --parallel ($jobs)"
  ^cmake --build $dir --parallel ($jobs | into string)

  print $"cmake --install ($dir)"
  ^cmake --install $dir

  print $"SUITE_BOOST_PREFIX=($prefix)"
}


def main [] {
  print "usage: nu suite.nu {package generic generic | install | run <name> <mask> <exe> [...rest] | info | hip-load-check | boost}"
}
