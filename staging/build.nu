# build.nu — the staging build.
#
# PHASE 1: install ROCm into the prefix, then configure. It stops after
# configure on purpose. Configure is where every path decision is made and
# CMakeCache.txt records what each one resolved to, so it is the cheap thing
# to iterate on locally; the build and install steps arrive once the
# configuration is settled and go to the runners.
#
# Every choice comes from variants.yaml by way of the recipe's env block.
# Nothing here decides a version.

let src = $env.SRC_DIR
let prefix = $env.PREFIX
let build_prefix = $env.BUILD_PREFIX
let recipe_dir = $env.RECIPE_DIR
let jobs = ($env.CPU_COUNT? | default "4" | into int)

# The conda toolkit root: CUDA packages install under it, and we put ROCm
# beside them so both backends have one root and acpp's own default hint
# (<root>/amdgcn/bitcode) finds the ROCm device libraries.
let targets_dir = ($prefix | path join "targets" "x86_64-linux")
let build_dir = ($src | path join ".." "llvm-build" | path expand)

print $"── environment ──"
print $"  SRC_DIR      ($src)"
print $"  PREFIX       ($prefix)"
print $"  BUILD_PREFIX ($build_prefix)"
print $"  RECIPE_DIR   ($recipe_dir)"
print $"  CPU_COUNT    ($jobs)"
print $"  sources      ((ls $src | get name | path basename | str join ', '))"

# ── ccache ───────────────────────────────────────────────────────────────
# CCACHE_DIR sits beside the recipe rather than in the work tree, so the
# workflow can save and restore it around an otherwise ephemeral build.
# BASEDIR rewrites paths under the work tree as relative, which is what lets
# a cache from one run hit on the next — the work directory is named
# differently every time. COMPILERCHECK=content because the compiler's mtime
# changes with every build environment even when the binary does not.
$env.CCACHE_DIR = ($recipe_dir | path join ".ccache")
$env.CCACHE_BASEDIR = $src
$env.CCACHE_COMPILERCHECK = "content"
mkdir $env.CCACHE_DIR
print $"── ccache ──"
print $"  dir     ($env.CCACHE_DIR)"
print $"  basedir ($env.CCACHE_BASEDIR)"
print $"  maxsize ($env.CCACHE_MAXSIZE)"

# ── ROCm ─────────────────────────────────────────────────────────────────
# TheRock's tarball is a build input that also ships: it is installed into
# the prefix BEFORE configure, so acpp finds it where the packaged toolchain
# will have it, and so the whole tree lands in the staging tarball for the
# packaging workspace to slice later.
let rocm_src = ($src | path join "rocm-dist")
let entries = (ls $rocm_src)
let dirs = ($entries | where type == dir)
let rocm_root = (
  if (($entries | length) == 1) and (($dirs | length) == 1) {
    # the archive carried a single top-level directory
    $dirs | first | get name
  } else {
    $rocm_src
  }
)
# TheRock's distribution is the whole ROCm stack, and it contains TWO install
# prefixes: its own at the root, and a complete LLVM at lib/llvm - AMD's clang
# toolchain, which acpp's doc/install-rocm.md explicitly recommends against
# building against. The root's `amdgcn` and `llvm` entries are symlinks down
# into that nested prefix; everything else at the root is ROCm's own.
#
# So we do not mirror either prefix. We name what is needed, take it from
# wherever it happens to live, and put it where it belongs under ONE prefix.
# The source column is an implementation detail of AMD's layout; the
# destination column is the contract with everything that will look for it.
#
# What is deliberately absent: the ML and math stack acpp never calls (MIOpen,
# hipDNN, hipTensor, rocSPARSE, rocShmem, Tensile's kernels), AMD's LLVM, and
# 2.4 GB of static archives. That is also what keeps the package buildable -
# rattler relocates every binary it packages, and patchelf fails outright on
# many of those files.
let rocm_keep_dirs = [
  [dest, src];

  # "Make sure to also install HIP (runtime libraries and headers)."
  ["include", "include"]

  # find_package(HIP) is not optional: when it misses, acpp falls back to
  # looking for hipcc AND reassigns ROCM_PATH to /opt/rocm, so a missing config
  # does not merely disable the backend, it moves every later lookup off our
  # prefix. hip-config-amd.cmake then find_dependency()s the other three.
  ["lib/cmake/hip", "lib/cmake/hip"]
  ["lib/cmake/hip-lang", "lib/cmake/hip-lang"]
  ["lib/cmake/amd_comgr", "lib/cmake/amd_comgr"]
  ["lib/cmake/hsa-runtime64", "lib/cmake/hsa-runtime64"]

  # The REAL config, not the root's shim - the shim includes a path inside
  # lib/llvm, which we do not ship. Placed here, its own three-level walk up
  # from lib/cmake/AMDDeviceLibs resolves to targets/x86_64-linux, so it finds
  # the bitcode below at exactly the path acpp's own hint uses.
  ["lib/cmake/AMDDeviceLibs", "lib/llvm/lib/cmake/AMDDeviceLibs"]

  # ROCM_DEVICE_LIBS_PATH. One copy, taken from where it actually lives; the
  # root's amdgcn is only a symlink to this.
  ["amdgcn/bitcode", "lib/llvm/amdgcn/bitcode"]
]

# The first five are the libraries acpp's OWN hip deployment manifest names
# (CMakeLists.txt, ACPP_HIP_DEPLOYMENT_MANIFEST). Its sixth, hsakmt, does not
# exist in this distribution at all - newer ROCm folded it into
# libhsa-runtime64 - so acpp will write HSAKMT_LIBRARY-NOTFOUND into the
# manifest it generates. That is a defect to fix for users of --acpp-deploy,
# not something this build can supply.
#
# hiprtc-builtins is NOT in that manifest; it is here because hiprtc loads it
# at JIT time. That one is our judgement, not upstream's.
let rocm_keep_libs = [
  "libamdhip64.so*"
  "libamd_comgr.so*"
  "libhsa-runtime64.so*"
  "libhiprtc.so*"
  "librocprofiler-register.so*"
  "libhiprtc-builtins.so*"
]

# hip-config.cmake set_and_checks both of these, which fails the configure
# outright if either is absent - and it EXECUTES hipconfig to decide the HIP
# platform unless told. We tell it (-DHIP_PLATFORM=amd), but the files still
# have to exist. 1.3 MB against the 338 MB of shipping bin/ wholesale.
let rocm_keep_files = ["bin/hipcc" "bin/hipconfig"]

print $"── ROCm ──"
print $"  from ($rocm_root)  ((du $rocm_root | get 0.physical))"
print $"  into ($targets_dir)"
mkdir $targets_dir
for d in $rocm_keep_dirs {
  let s = ($rocm_root | path join $d.src)
  let landed = ($targets_dir | path join $d.dest)

  if not ($s | path exists) {
    error make {msg: $"ROCm source directory is missing: ($s)"}
  }

  # `cp -r SRC DST` behaves differently depending on whether DST exists, and on
  # this runner neither branch produced the directory while also reporting no
  # error. So the branch is removed entirely: DST is created first, and its
  # CHILDREN are the copy sources. That is one behaviour, not two.
  #
  # -P keeps symlinks as symlinks. Without it the .so -> .so.N -> .so.N.N.N
  # chains become three identical files, and the layout stops being the one
  # every consumer's SONAME lookup expects.
  mkdir $landed
  let children = (glob ($s | path join "*"))
  if ($children | is-empty) {
    error make {msg: $"ROCm source directory is empty: ($s)"}
  }
  cp -r -P ...$children $landed

  let got = (ls $landed | length)
  print $"  dir  ($d.dest | fill -a l -w 26) <- ($d.src | fill -a l -w 32) ($got) entries, ((du $landed | get 0.physical))"
  if $got == 0 {
    error make {msg: $"ROCm copy produced nothing in ($landed) from ($children | length) sources"}
  }
}
for f in $rocm_keep_files {
  let s = ($rocm_root | path join $f)
  let landed = ($targets_dir | path join $f)
  if not ($s | path exists) {
    error make {msg: $"ROCm keep-list file is missing from the distribution: ($s)"}
  }
  mkdir ($landed | path dirname)
  cp $s $landed
  if not ($landed | path exists) {
    error make {msg: $"ROCm keep-list file did not land: ($landed)"}
  }
  print $"  file ($f | fill -a l -w 22) ((ls $landed | get 0.size))"
}

let libdir = ($targets_dir | path join "lib")
mkdir $libdir
for pat in $rocm_keep_libs {
  let matched = (glob ($rocm_root | path join "lib" $pat))
  if ($matched | is-empty) {
    error make {msg: $"ROCm keep-list pattern matched nothing: ($pat). The distribution's layout changed."}
  }
  cp -P ...$matched $libdir
  let links = ($matched | where {|f| (ls -l $f | get 0.type) == "symlink"} | length)
  print $"  libs ($pat | fill -a l -w 28) ($matched | length) files \(($links) symlinks\)"
}
print $"  installed ((du $targets_dir | get 0.physical)), ((ls $libdir | length)) libraries"

# ── the conda toolchain, resolved from the build environment ─────────────
# Derived rather than written down: a literal here is a literal that goes
# stale the first time conda moves a version.
let conda_triple = ($env.HOST? | default "")
if $conda_triple == "" {
  error make {msg: "HOST is not set; cannot determine the conda target triple"}
}

let declared_sysroot = ($env.CONDA_BUILD_SYSROOT? | default "")
let conda_sysroot = (if ($declared_sysroot != "") and ($declared_sysroot | path exists) {
  $declared_sysroot
} else {
  ($build_prefix | path join $conda_triple "sysroot")
})
if not ($conda_sysroot | path exists) {
  error make {msg: $"conda sysroot not found at ($conda_sysroot)"}
}

# --gcc-toolchain searches ${dir}/lib/gcc/${triple}/${version} and takes the
# largest version; --gcc-triple pins which triple it searches for, which is
# the half that would otherwise depend on the target. The alternative,
# --gcc-install-dir, names the versioned directory outright. This resolves the
# same installation either way, and the resolved path is still derived here so
# the pair can be checked against it.
let gcc_candidates = (glob ($build_prefix | path join "lib" "gcc" $conda_triple "*"))
if ($gcc_candidates | length) != 1 {
  error make {msg: $"expected exactly one gcc installation under ($build_prefix)/lib/gcc/($conda_triple), found ($gcc_candidates | length): ($gcc_candidates | str join ', ')"}
}
let gcc_install_dir = ($gcc_candidates | first)

print $"── conda toolchain ──"
print $"  triple      ($conda_triple)"
print $"  sysroot     ($conda_sysroot)"
print $"  gcc install ($gcc_install_dir)"

# The compile flags are captured and then REMOVED from the environment. The
# runtimes are configured by a child cmake that seeds CMAKE_C_FLAGS and
# CMAKE_CXX_FLAGS from the environment, and it compiles with the just-built
# clang rather than conda's gcc wrapper. That is how -fno-merge-constants -
# which gcc accepts and clang does not - reaches a clang that warns about it,
# and CMake's check_c_compiler_flag treats that warning as failure:
#
#   FAIL_REGEX "optimization flag [^\n]* not supported"    # Clang
#
# every probe in that configure then answers no, including -nostdinc++, which
# is what keeps libstdc++ out of the sanitizer sources.
#
# The outer configure is given the same flags explicitly, unchanged - it is
# compiled by conda's gcc, which accepts them. Only what reaches clang needs
# the flag removed, and that is the config files.
#
# LDFLAGS deliberately stays in the environment.
let cflags = ($env.CFLAGS? | default "")
let cxxflags = ($env.CXXFLAGS? | default "")
hide-env --ignore-errors CFLAGS
hide-env --ignore-errors CXXFLAGS


# Flags conda passes that clang does not accept. Removed only from the config
# files; the outer build keeps them. One entry today, and each one costs a
# whole configure's worth of feature detection, so the list is worth keeping.
let clang_rejects = ["-fno-merge-constants"]
def sanitise-for-clang [flags: string, rejects: list<string>] {
  $flags | split row -r '\s+' | where {|f| ($f != "") and (not ($f in $rejects))} | str join " "
}

# ── configure ────────────────────────────────────────────────────────────
# CMAKE_ARGS comes from the conda-forge activations and carries the sysroot,
# find-root and CUDA settings. It is a space separated string and must be
# splatted, never passed as one argument.
let conda_args = ($env.CMAKE_ARGS? | default "" | split row -r '\s+' | where {|a| $a != ""})

# The SPIR-V translator is configured by its own cmake invocation, which
# inherits none of this - that is how it found the distribution's LLVM instead
# of ours. It gets the same arguments, with two changes:
#
#   * CMAKE_INSTALL_PREFIX is dropped. acpp installs the translator into
#     lib/hipSYCL/ext/llvm-spirv and says so through an initial cache file,
#     which a command line -D would override - scattering an LLVM-SPIRV
#     installation across the toolchain root.
#   * The build tree joins CMAKE_FIND_ROOT_PATH, because the LLVM it links
#     against lives there rather than under the prefix or the sysroot, and the
#     find-root modes are ONLY.
#
# Values that are themselves lists switch to | for the trip through
# ExternalProject_Add, which claims the semicolon for its own argument
# splitting; the fork declares LIST_SEPARATOR | to turn them back.
let spirv_args = ($conda_args
  | where {|a| not ($a | str starts-with "-DCMAKE_INSTALL_PREFIX=")}
  | each {|a| if ($a | str starts-with "-DCMAKE_FIND_ROOT_PATH=") { $"($a);($build_dir)" } else { $a }}
  | each {|a| $a | str replace -a ";" "|"}
  | str join ";")
print $"── spirv sub-build ──"
print $"  ($spirv_args | split row ';' | length) arguments forwarded"
$spirv_args | split row ";" | each {|a| print $"    ($a | str substring 0..150)" }

let args = [
  -S ($src | path join "llvm-project" "llvm")
  -B $build_dir
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  $"-DCMAKE_INSTALL_PREFIX=($prefix)"
  # conda keeps libraries in plain lib, never lib64
  -DCMAKE_INSTALL_LIBDIR=lib

  # The triple the built compiler defaults to. Without this LLVM resolves
  # x86_64-unknown-linux-gnu, and clang's own GCC search then looks for
  # lib/gcc/x86_64-unknown-linux-gnu/<version> and misses conda's, which lives
  # under lib/gcc/x86_64-conda-linux-gnu/<version>. Setting it is what makes
  # the installed compiler find its toolchain with no flags at all - the same
  # reason conda-forge's own clang cfg files carry no --gcc-* option.
  # LLVM_HOST_TRIPLE implicitly sets LLVM_DEFAULT_TARGET_TRIPLE.
  $"-DLLVM_HOST_TRIPLE=($conda_triple)"

  # The shape of the toolchain, from variants.yaml.
  $"-DLLVM_ENABLE_PROJECTS=($env.LLVM_PROJECTS)"
  $"-DLLVM_ENABLE_RUNTIMES=($env.LLVM_RUNTIMES)"
  $"-DLLVM_TARGETS_TO_BUILD=($env.LLVM_TARGETS)"

  # AdaptiveCpp built as part of LLVM, its compiler components linked into
  # the LLVM tools. This is acpp's own documented flow, and the dylib flags
  # are part of it rather than a deviation.
  -DLLVM_BUILD_LLVM_DYLIB=ON
  -DLLVM_LINK_LLVM_DYLIB=ON
  -DLLVM_EXTERNAL_PROJECTS=AdaptiveCpp
  $"-DLLVM_EXTERNAL_ADAPTIVECPP_SOURCE_DIR=($src | path join 'AdaptiveCpp')"
  -DLLVM_ADAPTIVECPP_LINK_INTO_TOOLS=ON

  # acpp's from-source recommendations. Assertions are off because acpp can
  # trip false positives in some LLVM versions.
  -DLLVM_ENABLE_ASSERTIONS=OFF
  -DLLVM_ENABLE_DUMP=OFF
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_ENABLE_BINDINGS=OFF
  -DLLVM_ENABLE_OCAMLDOC=OFF
  -DOPENMP_ENABLE_LIBOMPTARGET=OFF

  # Link against the host packages rather than silently doing without them:
  # FORCE_ON fails the configure instead of quietly dropping a feature.
  -DLLVM_ENABLE_ZSTD=FORCE_ON
  -DLLVM_ENABLE_LIBXML2=FORCE_ON

  # lldb's bindings are compiled against whichever interpreter is resolved
  # here, which is why variants.yaml pins exactly one.
  -DLLDB_ENABLE_PYTHON=ON
  $"-DPython3_EXECUTABLE=($prefix | path join 'bin' 'python')"

  # Backends.
  -DWITH_CUDA_BACKEND=ON
  -DWITH_ROCM_BACKEND=ON
  -DWITH_LEVEL_ZERO_BACKEND=ON
  -DWITH_OPENCL_BACKEND=ON
  -DWITH_VULKAN_BACKEND=OFF

  # CUDA is found the way LLVM and acpp expect, from nvcc in the build
  # prefix. Only the device libraries are pointed at explicitly: conda puts
  # libdevice outside the toolkit root, and acpp bakes this path into
  # llvm-to-ptx, so it must be one that survives into the package.
  $"-DCUDA_DEVICE_LIBS_PATH=($prefix | path join 'nvvm' 'libdevice')"

  # AMD, stated rather than detected. hip-config.cmake runs `hipconfig
  # --platform` when HIP_PLATFORM is unset, and on a machine with CUDA present
  # and no AMD runtime that answers "nvidia" - which takes the NVIDIA branch,
  # where hip::host is an INTERFACE target carrying include directories and no
  # library at all. The HIP backend then links nothing and every hipMemcpy is
  # undefined. We are building the ROCm backend against an AMD distribution;
  # there is nothing to detect.
  -DHIP_PLATFORM=amd

  # ROCm has no compiler package doing that work, so it is told directly. The
  # device libraries are named explicitly rather than left to the hint off
  # ROCM_PATH: acpp reassigns ROCM_PATH when HIP detection fails, so a hint
  # that depends on it turns one failure into two.
  $"-DROCM_PATH=($targets_dir)"
  $"-DROCM_DEVICE_LIBS_PATH=($targets_dir | path join 'amdgcn' 'bitcode')"

  # Pin the SPIR-V translator rather than tracking a branch.
  $"-DLLVMSPIRV_COMMIT=($env.LLVMSPIRV_COMMIT)"

  # The translator is a sub-build, and acpp forwards ${LLVM_DIR} into it. When
  # AdaptiveCpp is built as an LLVM component nothing calls find_package(LLVM),
  # so that variable is empty and the sub-build's own find_package(LLVM 21.1.0)
  # falls through to the system - on this runner, Ubuntu's llvm-16/17/18, none
  # of which it accepts. Point it at the LLVM being built, whose build tree
  # exports LLVMConfig.cmake at configure time.
  $"-DLLVM_DIR=($build_dir | path join 'lib' 'cmake' 'llvm')"

  # Leave the build machine's paths out of the installed configuration, and out
  # of the deployment manifests and the binaries. What a package we redistribute
  # records about this machine should be nothing.
  -DACPP_CONFIG_FILE_OMIT_ENVIRONMENT_PATHS=ON
  -DACPP_OMIT_RECORDED_INSTALL_PREFIX=ON

  # The same rule for LLVM's own output: -ffile-prefix-map over the source root
  # and the build directory, which reaches the runtimes children too
  # (LLVMExternalProjectUtils forwards it), so compiler-rt stops carrying our
  # paths in its debug info. Fuchsia's release caches set this, so it is a
  # supported configuration rather than an obscure one.
  -DLLVM_USE_RELATIVE_PATHS_IN_FILES=ON

  # Not because we ship lit and FileCheck - we do not, and what we ship is a
  # slicing decision made later. It is that the install-tree LLVMConfig.cmake
  # only recomputes LLVM_DEFAULT_EXTERNAL_LIT inside
  # `if(LLVM_INSTALL_UTILS AND LLVM_BUILD_UTILS)`; with the guard false the
  # variable keeps the value the BUILD-tree pass gave it, and a build path ships
  # inside an installed cmake package.
  -DLLVM_INSTALL_UTILS=ON

  # Everything the translator's own cmake needs, since it inherits nothing.
  $"-DACPP_SPIRV_CMAKE_ARGS=($spirv_args)"

  # Passed explicitly because they have been taken out of the environment.
  # Unsanitised: this build is driven by conda's gcc, which accepts them.
  $"-DCMAKE_C_FLAGS=($cflags)"
  $"-DCMAKE_CXX_FLAGS=($cxxflags)"

  -DCMAKE_C_COMPILER_LAUNCHER=ccache
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache

  # A cap computed from memory actually available, rather than a number that
  # is wrong on one runner or the other. LLVM applies no cap by default.
  -DLLVM_RAM_PER_LINK_JOB=4096
]

print $"── configure ──"
print $"  build dir ($build_dir)"
print $"  conda CMAKE_ARGS: ($conda_args | length) arguments"
mkdir $build_dir
cmake ...$args ...$conda_args

print $"── configured ──"
print $"  cache ($build_dir | path join 'CMakeCache.txt')"

# ── clang configuration files ────────────────────────────────────────────
# BUILD-ONLY. These are never installed: the shipped compiler's config files
# belong to the activation packages and match upstream's. These exist so that
# everything compiled with the just-built clang during this build - the
# compiler-rt runtimes above all - uses the SAME options as everything else
# in the toolchain. A distribution whose own pieces were compiled with
# different options is binary-incompatible with itself.
#
# Clang searches the directory its executable lives in, and falls back from
# <triple>-<driver>.cfg to <driver>.cfg, so a plain name beside the binary is
# found. Paths are absolute because this file never leaves the build tree;
# upstream's use <CFGDIR> because theirs ships.
#
# The link line's options are each prefixed with `$`. That is a real feature
# and it is not in the user manual - Driver.cpp:1247 sorts config options into
# a head list and a tail list, and "the tail list is used only when linking",
# with the `$` stripped. Without it every compile-only invocation would carry
# linker flags it cannot use. It is per OPTION, not per line, which is why
# LDFLAGS is split before being marked.
#
# The names carry the HOST TRIPLE, and that is the whole point rather than a
# convention. Clang looks first for <triple>-<driver>.cfg using the triple of
# the target being compiled, so a host compile finds these and a device
# compile - acpp builds its SSCP bitcode for nvptx64-nvidia-cuda,
# spir64-unknown-unknown and amdgcn-amd-amdhsa with this same clang - looks for
# a name that does not exist and gets nothing. A plain clang.cfg would be found
# by BOTH, and -march=nocona is not a thing on NVPTX.
let cfg_dir = ($build_dir | path join "bin")
mkdir $cfg_dir
let link_tail = ($env.LDFLAGS? | default "" | split row -r '\s+' | where {|t| $t != ""} | each {|t| ('$' + $t)} | str join " ")
print $"── clang cfg ──"
for d in [[driver, flags]; ["clang", (sanitise-for-clang $cflags $clang_rejects)] ["clang++", (sanitise-for-clang $cxxflags $clang_rejects)]] {
  let path = ($cfg_dir | path join $"($conda_triple)-($d.driver).cfg")
  [
    $"--sysroot=($conda_sysroot) --gcc-toolchain=($build_prefix) --gcc-triple=($conda_triple)"
    # The DWARF compilation directory, which is this build tree and is nobody's
    # business but ours. conda's own CFLAGS map $SRC_DIR and $PREFIX but not the
    # build directory, and LLVM_USE_RELATIVE_PATHS_IN_FILES does not reach
    # compiler-rt, which assembles its own flag lists rather than inheriting
    # CMAKE_C_FLAGS - measured: its objects carry a mapped source path beside an
    # unmapped comp_dir. A config file applies to every invocation of this
    # compiler whatever cmake hands it, which is the only place that holds.
    $"-ffile-prefix-map=($build_dir)=."
    $d.flags
    $link_tail
  ] | str join "\n" | save -f $path
  print $"  ($path)"
  open --raw $path | lines | each {|l| print $"    ($l | str substring 0..150)" }
}

# ── build and install ────────────────────────────────────────────────────
# Link concurrency is governed by LLVM_RAM_PER_LINK_JOB, set at configure:
# LLVM sizes its own job pool from the memory actually available, so --parallel
# here is the COMPILE width and links throttle themselves underneath it.
# clang is built first so the configuration files can be PROVEN before the
# runtimes are compiled with them. acpp's own documentation warns that clang
# silently ignores a gcc path it does not accept, so "did the cfg take" is a
# question that must be answered by asking clang, not by reading the file we
# just wrote. `-v /dev/null` is expected to fail at the link step; its stderr
# is the answer.
print $"── build: clang first, to prove the configuration ──"
cmake --build $build_dir --parallel $jobs --target clang

# `clang`, not `clang++`: the ++ name is a symlink created by a separate
# target, so it need not exist yet. Both read their own cfg and both print the
# line we are checking.
let probe = (do -i { ^($cfg_dir | path join "clang") -v /dev/null } | complete)
let selected = ($probe.stderr | lines | where {|l| $l =~ 'Selected GCC installation'} | first | default "")
print $"  ($selected | str trim)"
if not ($selected | str contains $gcc_install_dir) {
  print "  ── clang -v, in full ──"
  $probe.stderr | lines | first 25 | each {|l| print $"    ($l | str substring 0..170)" }
  error make {msg: $"clang did not select the conda gcc installation. Wanted ($gcc_install_dir), got: ($selected | str trim)"}
}

print $"── build ──"
cmake --build $build_dir --parallel $jobs

# No --prefix. CMAKE_INSTALL_PREFIX was fixed at configure time, and acpp
# baked it into the SPIR-V translator's own install prefix there; redirecting
# now would move everything except the translator.
print $"── install ──"
cmake --install $build_dir

print $"── installed ──"
print $"  prefix ($prefix)  ((du $prefix | get 0.physical))"
for e in (ls $prefix | sort-by name) {
  print $"    ($e.name | path basename | fill -a l -w 16) ((du $e.name | get 0.physical))"
}
let cache_stats = (do -i { ^ccache --show-stats --verbose } | complete)
if $cache_stats.exit_code == 0 {
  print $"── ccache ──"
  $cache_stats.stdout | lines | where {|l| ($l =~ '(?i)hit|miss|size')} | first 8 | each {|l| print $"  ($l | str trim)" }
}
