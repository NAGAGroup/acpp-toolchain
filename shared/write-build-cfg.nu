#!/usr/bin/env nu
# write-build-cfg.nu — clang config files for the FRESHLY BUILT clang, in the
# BUILD tree's bin dir (<build>/bin), so every host-side invocation of the
# bootstrapped clang gets the isolation the conda compiler activation gives the
# outer compiler: sysroot / SDK, gcc toolchain, deployment target, libc++ headers
# and the activation flags.
#
# Why: the LLVM_ENABLE_RUNTIMES child (compiler-rt, libomp) is a SEPARATE cmake
# driven by <build>/bin/clang, and ninja-spawned configures never see the
# outer flags. main() of build-stage.nu strips CFLAGS/CXXFLAGS/CPPFLAGS from the
# env (runs 31346899644 / 5e5a666 history), so the child only gets what
# RUNTIMES_CMAKE_ARGS hands it. A cfg file next to the clang follows EVERY
# invocation, whatever configures it (the runtimes child, builtins, anything
# else the bootstrapped clang compiles for the host).
#
# Mechanism (clang docs, "Configuration files"): for the driver mode of the
# invoked name clang loads <triple>-<driver>.cfg from its own directory, where
# <triple> is the effective target (--target, or the default target). We write
#   <T>-clang.cfg   (C),  <T>-clang++.cfg  (C++),  <T>-clang-cpp.cfg (preprocessor)
# for every triple spelling T the host-side invocations use, and NEVER a plain
# clang.cfg / clang++.cfg / clang-cpp.cfg / <arch>.cfg: device-target
# invocations (spir64, nvptx64, amdgcn) must not load anything.
#
# Runs BEFORE main() strips the activation env, so CFLAGS, CXXFLAGS, CPPFLAGS,
# LDFLAGS, CONDA_BUILD_SYSROOT, BUILD_PREFIX, PREFIX, SDKROOT /
# CMAKE_OSX_SYSROOT and MACOSX_DEPLOYMENT_TARGET are all still present.
# Absolute paths only, one option per line. Not the install-time
# shared/activation/install-cfg.nu (that one writes the relocatable
# <CFGDIR>-relative files shipped in $PREFIX/bin).
#
# Usage: nu write-build-cfg.nu <build-dir>

source build-stage-lib.nu

# Flag units never written. Each was tested against the published clang 23 with
# -Werror=unknown-argument -Werror=unused-command-line-argument
# -Werror=ignored-optimization-argument; everything else in the conda
# activation flags of linux-64, linux-aarch64 and osx-arm64 passes.
const DROP_UNITS = [
  # gcc-only. clang parses it and ignores it, printing
  # -Wignored-optimization-argument on every single compile.
  "-fno-merge-constants"
]

# Options whose argument is a separate word; the pair stays on one cfg line.
const TWO_WORD_OPTIONS = ["-isystem" "-I" "-L" "-include" "-iquote" "-idirafter" "-isysroot" "-stdlib++-isystem" "/I" "-imsvc" "/imsvc" "/external:I"]

# An environment variable as a string; unset -> "".
def env-or-empty [name: string] {
  $env | get -o $name | default "" | into string
}

# Split a flag string into units, one per cfg line. An option that takes its
# argument as a separate word keeps it ("-isystem /dir").
def flag-units [flags: string] {
  let words = ($flags | split row -r '\s+' | where {|w| $w != "" })
  mut out = []
  mut i = 0
  while $i < ($words | length) {
    let w = ($words | get $i)
    if ($w in $TWO_WORD_OPTIONS) and ($i + 1) < ($words | length) {
      $out = ($out | append $"($w) ($words | get ($i + 1))")
      $i = $i + 2
    } else {
      $out = ($out | append $w)
      $i = $i + 1
    }
  }
  $out
}

# Drop the units clang rejects or warns about; remove duplicates, keep order.
def keep-units [units: list<string>] {
  $units | where {|u| not ($u in $DROP_UNITS) } | uniq
}

# Write one cfg file; returns the path.
def write-cfg [bin: string, triple: string, driver: string, header: string, lines: list<string>] {
  let path = ($bin | path join $"($triple)-($driver).cfg")
  ([$header] ++ $lines | str join "\n") + "\n" | save --force $path
  $path
}

# ---- Linux -------------------------------------------------------------------
# Same sysroot choice as conda-toolchain-args: CONDA_BUILD_SYSROOT, else the
# conda layout under BUILD_PREFIX. --sysroot finds the C library headers (glibc
# 2.28), --gcc-toolchain the C++ stdlib headers (libstdc++): exactly what
# RUNTIMES_CMAKE_ARGS passes, now for every invocation.
def linux-cfgs [bin: string] {
  let triple = (linux-triple)
  let bp = (env-or-empty BUILD_PREFIX)
  let sysroot_env = (env-or-empty CONDA_BUILD_SYSROOT)
  let derived = (if $bp != "" { [$bp $triple "sysroot"] | path join } else { "" })
  let sysroot = (if ($sysroot_env != "" and ($sysroot_env | path exists)) {
    $sysroot_env
  } else if ($derived != "" and ($derived | path exists)) {
    $derived
  } else {
    ""
  })
  if $sysroot == "" or $bp == "" {
    error make {msg: "write-build-cfg: no conda sysroot or BUILD_PREFIX (CONDA_BUILD_SYSROOT unset and the BUILD_PREFIX layout is absent)"}
  }

  let cflags = (env-or-empty CFLAGS)
  let cxxflags = (env-or-empty CXXFLAGS)
  let cppflags = (env-or-empty CPPFLAGS)
  let ldflags = (env-or-empty LDFLAGS)
  let iso = [$"--sysroot=($sysroot)" $"--gcc-toolchain=($bp)"]
  let ld = (keep-units (flag-units $ldflags))
  let c_lines = $iso ++ (keep-units ((flag-units $cflags) ++ (flag-units $cppflags))) ++ $ld
  let cxx_lines = $iso ++ (keep-units ((flag-units $cxxflags) ++ (flag-units $cppflags))) ++ $ld
  let cpp_lines = $iso ++ (keep-units (flag-units $cppflags))

  # The runtimes COMPILER_TARGET and LLVM_DEFAULT_TARGET_TRIPLE / LLVM_HOST_TRIPLE
  # (linux-args) are all (linux-triple): one spelling.
  [$triple] | uniq | each {|t|
    let note = $"# Build-tree clang config for ($t), written by shared/write-build-cfg.nu. Not shipped."
    [
      {path: (write-cfg $bin $t "clang" $"($note) C driver." $c_lines), token: $sysroot}
      {path: (write-cfg $bin $t "clang++" $"($note) C++ driver." $cxx_lines), token: $sysroot}
      {path: (write-cfg $bin $t "clang-cpp" $"($note) Preprocessor driver." $cpp_lines), token: $sysroot}
    ]
  } | flatten
}

# ---- macOS -------------------------------------------------------------------
# The SDK comes from SDKROOT (sdkroot_env activation), else CMAKE_OSX_SYSROOT,
# else the -DCMAKE_OSX_SYSROOT in the activation's CMAKE_ARGS.
# The deployment target is the INTENDED one: c_stdlib_version in
# shared/variants/osx-arm64.yaml (commit 968a7c0 "target macOS 26"; the build env
# installs macosx_deployment_target_osx-arm64 26.0). The activation script read
# MACOSX_DEPLOYMENT_TARGET=11.0 into CPPFLAGS and CMAKE_ARGS (round 6 log), which
# disagrees with it; so the activation's own -mmacosx-version-min is dropped
# and replaced. Falls back to the env var when the variants file is unreadable.
def darwin-cfgs [bin: string] {
  let bp = (env-or-empty BUILD_PREFIX)
  let prefix = (env-or-empty PREFIX)
  let cmake_args = (env-or-empty CMAKE_ARGS)
  let from_cmake = ($cmake_args | split row -r '\s+' | where {|a| $a | str starts-with "-DCMAKE_OSX_SYSROOT=" } | each {|a| $a | str replace "-DCMAKE_OSX_SYSROOT=" "" } | get -o 0 | default "")
  let sdk = ([(env-or-empty SDKROOT) (env-or-empty CMAKE_OSX_SYSROOT) $from_cmake] | where {|s| $s != "" } | get -o 0 | default "")
  if $sdk == "" or not ($sdk | path exists) {
    error make {msg: $"write-build-cfg: no usable macOS SDK \(SDKROOT / CMAKE_OSX_SYSROOT / CMAKE_ARGS gave '($sdk)'\)"}
  }

  let env_dt = (env-or-empty MACOSX_DEPLOYMENT_TARGET)
  let variants = ($env.FILE_PWD | path join "variants" "osx-arm64.yaml")
  let intended = (try { open $variants | get c_stdlib_version | first | into string } catch { "" })
  let dt = (if $intended != "" { $intended } else { $env_dt })
  if $dt == "" { error make {msg: "write-build-cfg: no deployment target (variants file unreadable and MACOSX_DEPLOYMENT_TARGET unset)"} }
  print $"write-build-cfg: deployment target ($dt) \(variants c_stdlib_version='($intended)', env MACOSX_DEPLOYMENT_TARGET='($env_dt)')"
  if $intended != "" and $env_dt != "" and $intended != $env_dt {
    print $"write-build-cfg: WARNING env MACOSX_DEPLOYMENT_TARGET ($env_dt) differs from the intended ($intended); using the intended value"
  }

  # libc++ headers: the conda libcxx-devel sits in the staging BUILD env
  # (clangxx_osx-arm64 depends on it; the outer build uses it), the host env only
  # has the libcxx runtime. Prefer BUILD_PREFIX, fall back to PREFIX.
  let libcxx = ([$bp $prefix] | where {|p| $p != "" } | each {|p| $p | path join "include" "c++" "v1" } | where {|d| $d | path exists } | get -o 0 | default "")
  if $libcxx == "" {
    error make {msg: $"write-build-cfg: no libc++ headers under BUILD_PREFIX/PREFIX include/c++/v1 \(BUILD_PREFIX='($bp)', PREFIX='($prefix)'\)"}
  }

  let not_vmin = {|u| not ($u | str starts-with "-mmacosx-version-min=") }
  let cflags = (flag-units (env-or-empty CFLAGS))
  let cxxflags = (flag-units (env-or-empty CXXFLAGS))
  let cppflags = (flag-units (env-or-empty CPPFLAGS))
  let ld = (keep-units (flag-units (env-or-empty LDFLAGS)))
  let iso = [$"-isysroot ($sdk)" $"-mmacosx-version-min=($dt)"]
  let c_lines = $iso ++ (keep-units (($cflags ++ $cppflags) | where $not_vmin)) ++ $ld
  let cxx_lines = $iso ++ (keep-units (($cxxflags ++ $cppflags) | where $not_vmin)) ++ [$"-stdlib++-isystem ($libcxx)"] ++ $ld
  let cpp_lines = $iso ++ (keep-units ($cppflags | where $not_vmin))

  # Runtimes child: CMAKE_{C,CXX}_COMPILER_TARGET = LLVM_TARGET_TRIPLE =
  # LLVM_DEFAULT_TARGET_TRIPLE = arm64-apple-darwin20.0.0 (darwin-args). In the
  # upstream tree at 3e7a2ec7 LLVMExternalProjectUtils.cmake passes
  # --target=<that spelling> only (TARGET_TRIPLE in runtimes/CMakeLists.txt) and
  # derives no other triple from it.
  ["arm64-apple-darwin20.0.0"] | uniq | each {|t|
    let note = $"# Build-tree clang config for ($t), written by shared/write-build-cfg.nu. Not shipped."
    [
      {path: (write-cfg $bin $t "clang" $"($note) C driver." $c_lines), token: $sdk}
      {path: (write-cfg $bin $t "clang++" $"($note) C++ driver." $cxx_lines), token: $sdk}
      {path: (write-cfg $bin $t "clang-cpp" $"($note) Preprocessor driver." $cpp_lines), token: $sdk}
    ]
  } | flatten
}

# ---- Windows -----------------------------------------------------------------
# Probed locally with clang 23: default config files DO load in cl driver mode,
# as <T>-clang-cl.cfg. The runtimes child on both Windows platforms is
# <build>/bin/clang-cl.exe (round 6 logs), ASM included, so ONLY that file is
# written: the cl-style include options (/I, -imsvc) are errors in gnu mode, and
# clang-cl has one cfg for C and C++ alike. The activation provides NO
# compile flags there: the MSVC activation exports only INCLUDE and LIB, which
# the child inherits and which are the real isolation; CFLAGS/CXXFLAGS are
# normally unset. So only include-path options are ever carried over - nothing
# that touches /DWIN32, /EH, /M*, /O* or any other MSVC default (run 31350122413
# was exactly such a clobber). When nothing qualifies, nothing is written.
def windows-cfgs [bin: string] {
  let triple = (if (is-arm) { "aarch64-pc-windows-msvc" } else { "x86_64-pc-windows-msvc" })
  let allowed = {|u| $u =~ '^(-I|/I|-imsvc|/imsvc|/external:I)' }
  let units = ((flag-units (env-or-empty CFLAGS)) ++ (flag-units (env-or-empty CXXFLAGS)) ++ (flag-units (env-or-empty CPPFLAGS)))
  let lines = (keep-units $units | where $allowed)
  if ($lines | is-empty) {
    print $"write-build-cfg: windows: no activation include flags to carry over; writing nothing. Isolation comes from the INCLUDE/LIB env of the MSVC activation, inherited by the runtimes child."
    return []
  }
  let note = $"# Build-tree clang config for ($triple), written by shared/write-build-cfg.nu. Not shipped. Include paths only."
  [{path: (write-cfg $bin $triple "clang-cl" $"($note) cl driver." $lines), token: ($lines | first)}]
}

def main [build: string] {
  let bin = ($build | path join "bin")
  mkdir $bin

  let written = (if (is-windows) {
    windows-cfgs $bin
  } else if (is-darwin) {
    darwin-cfgs $bin
  } else {
    linux-cfgs $bin
  })

  # Fail fast: every expected file exists and carries its sysroot / SDK token.
  for w in $written {
    if not ($w.path | path exists) { error make {msg: $"write-build-cfg: expected ($w.path) was not written"} }
    if ($w.token != "") and not (open --raw $w.path | str contains $w.token) {
      error make {msg: $"write-build-cfg: ($w.path) does not contain '($w.token)'"}
    }
  }

  for w in $written {
    print $"--- ($w.path)"
    print (open --raw $w.path)
  }
  print $"write-build-cfg: wrote ($written | length) file\(s) into ($bin)"
}
