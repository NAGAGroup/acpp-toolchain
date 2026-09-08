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
# TheRock's distribution is 11.7 GB of the whole ROCm stack. We take a KEEP
# LIST rather than a skip list, because we know exactly what is wanted and
# guessing at exclusions leaves the rest to chance.
#
# The libraries are the ones acpp's own hip deployment manifest names -
# amdhip64, hsa-runtime64, amd_comgr, hiprtc - so the list comes from acpp
# rather than from us. Everything else is an ML and math stack acpp never
# calls: MIOpen, hipDNN, hipTensor, rocSPARSE, rocShmem, Tensile's kernels,
# rocprofiler, ROCm's own clang (twice, at llvm/ and lib/llvm), and 2.4 GB of
# static archives that could not be a runtime dependency of anything.
#
# It is also what keeps the package buildable: rattler must relocate every
# binary it packages, and patchelf fails outright on many of those files.
#
# If the ROCm backend later turns out to need one more library, this is a
# one-line addition - and the moment to make it is when we can test on AMD
# hardware, not now.
# amdgcn is the device bitcode; include is the HIP headers; lib/cmake is HIP's
# CMake package, and it is NOT optional even though nothing installs from it.
# acpp does find_package(HIP ... HINTS ${ROCM_PATH} ${ROCM_PATH}/lib/cmake),
# and when that misses it falls back to hipcc AND reassigns ROCM_PATH to
# /opt/rocm - so a missing CMake package does not merely disable the ROCm
# backend, it moves every later lookup off our prefix. 1.5 MB.
let rocm_keep_dirs = ["amdgcn" "include" "lib/cmake"]
let rocm_keep_libs = [
  "libamdhip64.so*"
  "libamd_comgr.so*"
  "libhsa-runtime64.so*"
  "libhiprtc.so*"
  "libhiprtc-builtins.so*"
]

print $"── ROCm ──"
print $"  from ($rocm_root)  ((du $rocm_root | get 0.physical))"
print $"  into ($targets_dir)"
mkdir $targets_dir
for d in $rocm_keep_dirs {
  let s = ($rocm_root | path join $d)
  let dest = ($targets_dir | path join $d | path dirname)
  mkdir $dest
  cp -r $s $dest
  let landed = ($targets_dir | path join $d)
  if not ($landed | path exists) {
    error make {msg: $"ROCm keep-list directory did not land: ($landed)"}
  }
  print $"  dir  ($d | fill -a l -w 22) ((du $landed | get 0.physical))  -> ($landed)"
}
let libdir = ($targets_dir | path join "lib")
mkdir $libdir
for pat in $rocm_keep_libs {
  let matched = (glob ($rocm_root | path join "lib" $pat))
  if ($matched | is-empty) {
    error make {msg: $"ROCm keep-list pattern matched nothing: ($pat). The distribution's layout changed."}
  }
  cp ...$matched $libdir
  print $"  libs ($pat | fill -a l -w 22) ($matched | length) files"
}
print $"  installed ((du $targets_dir | get 0.physical)), ((ls $libdir | length)) libraries"

# ── configure ────────────────────────────────────────────────────────────
# CMAKE_ARGS comes from the conda-forge activations and carries the sysroot,
# find-root and CUDA settings. It is a space separated string and must be
# splatted, never passed as one argument.
let conda_args = ($env.CMAKE_ARGS? | default "" | split row -r '\s+' | where {|a| $a != ""})

let args = [
  -S ($src | path join "llvm-project" "llvm")
  -B $build_dir
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  $"-DCMAKE_INSTALL_PREFIX=($prefix)"
  # conda keeps libraries in plain lib, never lib64
  -DCMAKE_INSTALL_LIBDIR=lib

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

  # ROCm has no compiler package doing that work, so it is told directly. The
  # device libraries are named explicitly rather than left to the hint off
  # ROCM_PATH: acpp reassigns ROCM_PATH when HIP detection fails, so a hint
  # that depends on it turns one failure into two.
  $"-DROCM_PATH=($targets_dir)"
  $"-DROCM_DEVICE_LIBS_PATH=($targets_dir | path join 'amdgcn' 'bitcode')"

  # Pin the SPIR-V translator rather than tracking a branch.
  $"-DLLVMSPIRV_COMMIT=($env.LLVMSPIRV_COMMIT)"

  # Leave the build machine's paths out of the installed configuration.
  -DACPP_CONFIG_FILE_OMIT_ENVIRONMENT_PATHS=ON

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

# ── build and install ────────────────────────────────────────────────────
# Link concurrency is governed by LLVM_RAM_PER_LINK_JOB, set at configure:
# LLVM sizes its own job pool from the memory actually available, so --parallel
# here is the COMPILE width and links throttle themselves underneath it.
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
