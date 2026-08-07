# build.nu — single cross-platform build driver for the acpp toolchain suites.
#
# Every toolchain package recipe (release + nightly) runs:
#     nu shared/build.nu toolchain
# The script maintains a PERSISTENT source + CMake build cache per lane, so
# the first invocation does the full LLVM+AdaptiveCpp build and every
# subsequent invocation (other packages of the lane, rebuilds) is
# fetch-verify → cmake no-op → install-into-$PREFIX. Recipes then carve
# their slice of $PREFIX with `build.files` globs.
#
# Inputs (env, set by each recipe's script.env — the recipe is the pin
# source of truth):
#   ACPP_LANE            release | nightly
#   ACPP_LLVM_VERSION    e.g. 20.1.8
#   ACPP_ACPP_REF        git ref for AdaptiveCpp (tag or branch)
#   ACPP_ACPP_COMMIT     pinned commit ("" => resolve ref HEAD, i.e. nightly)
#   ACPP_SPIRV_COMMIT    AdaptiveCpp/SPIRV-LLVM-Translator commit
#   ACPP_OCLH_COMMIT     KhronosGroup/OpenCL-Headers commit
#   ACPP_OCLHPP_COMMIT   KhronosGroup/OpenCL-CLHPP commit
#   ACPP_BUILD_CACHE     persistent cache root (workspace tasks set this to
#                        <repo>/.build-cache; falls back to a work-dir-
#                        adjacent dir, which loses cross-package reuse)
# Plus rattler-build's: PREFIX, SRC_DIR, RECIPE_DIR, CPU_COUNT.

# ---------------------------------------------------------------------------
def is-windows [] { $nu.os-info.name == "windows" }

def cpu-count [] {
  $env.CPU_COUNT? | default (sys cpu | length | into string) | into int
}

def config [] {
  let lane = ($env.ACPP_LANE? | default "release")
  let cache_root = (
    if (($env.ACPP_BUILD_CACHE? | default "") != "") {
      $env.ACPP_BUILD_CACHE
    } else {
      # fallback: sibling of the ephemeral work dir (still out-of-tree,
      # survives within one pixi build-dir session)
      ($env.SRC_DIR | path join ".." "acpp-build-cache" | path expand)
    }
  )
  let lane_dir = ($cache_root | path join $lane)
  {
    lane: $lane
    llvm_version: $env.ACPP_LLVM_VERSION
    acpp_ref: $env.ACPP_ACPP_REF
    acpp_commit: ($env.ACPP_ACPP_COMMIT? | default "")
    spirv_commit: $env.ACPP_SPIRV_COMMIT
    oclh_commit: $env.ACPP_OCLH_COMMIT
    oclhpp_commit: $env.ACPP_OCLHPP_COMMIT
    cache: $lane_dir
    llvm_src: ($lane_dir | path join "llvm-project")
    acpp_src: ($lane_dir | path join "AdaptiveCpp")
    spirv_src: ($lane_dir | path join "SPIRV-LLVM-Translator")
    oclh_src: ($lane_dir | path join "OpenCL-Headers")
    oclhpp_src: ($lane_dir | path join "OpenCL-CLHPP")
    build_dir: ($lane_dir | path join "build")
    prefix: $env.PREFIX
  }
}

# Clone/verify a repo at a pinned commit. If `commit` is empty, resolve the
# ref's current HEAD (nightly) and return the resolved sha.
def ensure-repo [dir: string, url: string, ref: string, commit: string] {
  if ($dir | path exists) {
    let head = (^git -C $dir rev-parse HEAD | str trim)
    if ($commit != "" and $head == $commit) { return $head }
    if ($commit == "") {
      # nightly: advance to current remote head of ref
      ^git -C $dir fetch --depth 1 origin $ref
      ^git -C $dir checkout --detach FETCH_HEAD
      return (^git -C $dir rev-parse HEAD | str trim)
    }
    # pinned but wrong commit → re-fetch the pin
    ^git -C $dir fetch --depth 1 origin $commit
    ^git -C $dir checkout --detach $commit
    return (^git -C $dir rev-parse HEAD | str trim)
  }
  mkdir $dir
  ^git -C $dir init -q
  ^git -C $dir remote add origin $url
  if ($commit != "") {
    ^git -C $dir fetch --depth 1 origin $commit
    ^git -C $dir checkout --detach $commit
  } else {
    ^git -C $dir fetch --depth 1 origin $ref
    ^git -C $dir checkout --detach FETCH_HEAD
  }
  ^git -C $dir rev-parse HEAD | str trim
}

# Idempotently redirect AdaptiveCpp's SPIRV-LLVM-Translator ExternalProject
# from its moving-branch git clone to our pinned local checkout
# (build passes -DLLVMSPIRV_SOURCE_DIR). Regex-based so it survives both
# the v25.10.0 and develop layouts of the block.
def patch-spirv-redirect [acpp_src: string] {
  let f = ($acpp_src | path join "src" "compiler" "llvm-to-backend" "CMakeLists.txt")
  let content = (open --raw $f)
  if ($content | str contains "LLVMSPIRV_SOURCE_DIR") { return }
  let patched = ($content
    | str replace --regex '(?s)GIT_REPOSITORY https://github\.com/AdaptiveCpp/SPIRV-LLVM-Translator\s+GIT_TAG origin/\$\{LLVMSPIRV_BRANCH\}\s+GIT_SHALLOW ON\s+GIT_REMOTE_UPDATE_STRATEGY CHECKOUT'
      'SOURCE_DIR ${LLVMSPIRV_SOURCE_DIR}')
  if $patched == $content {
    error make { msg: $"spirv-redirect: pattern not found in ($f) — upstream layout changed, update build.nu" }
  }
  $patched | save --force --raw $f
  print "spirv-redirect: patched ExternalProject to use LLVMSPIRV_SOURCE_DIR"
}

def fetch-sources [] {
  let c = (config)
  mkdir $c.cache
  let llvm_sha = (ensure-repo $c.llvm_src "https://github.com/llvm/llvm-project" $"llvmorg-($c.llvm_version)" "")
  print $"llvm-project @ ($llvm_sha)"
  let acpp_sha = (ensure-repo $c.acpp_src "https://github.com/AdaptiveCpp/AdaptiveCpp" $c.acpp_ref $c.acpp_commit)
  print $"AdaptiveCpp @ ($acpp_sha) (ref ($c.acpp_ref))"
  ensure-repo $c.spirv_src "https://github.com/AdaptiveCpp/SPIRV-LLVM-Translator" "" $c.spirv_commit | ignore
  ensure-repo $c.oclh_src "https://github.com/KhronosGroup/OpenCL-Headers" "" $c.oclh_commit | ignore
  ensure-repo $c.oclhpp_src "https://github.com/KhronosGroup/OpenCL-CLHPP" "" $c.oclhpp_commit | ignore
  patch-spirv-redirect $c.acpp_src
  { acpp_sha: $acpp_sha } | save --force ($c.cache | path join "resolved.nuon")
}

# LLVM tags pinned by release TAG (annotated); resolve expected commit lazily:
# llvm-project is pinned by its release tag, which upstream never moves.
# (AdaptiveCpp/SPIRV/Khronos pins are exact commits.)

def link-jobs [] {
  if (is-windows) { return 2 }
  let mem_gb = ((open /proc/meminfo | lines | first | parse "MemTotal:{kb} kB" | get kb.0 | str trim | into int) / 1048576 | math round)
  [1 ([($mem_gb // 4) (cpu-count)] | math min)] | math max
}

def configure [] {
  let c = (config)
  if (($c.build_dir | path join "CMakeCache.txt") | path exists) {
    print "configure: CMakeCache.txt present — skipping (incremental)"
    return
  }
  mkdir $c.build_dir
  # conda gxx makes CMake treat this as pseudo-cross; LLVM's runtime
  # sub-configures need the build dir on CMAKE_PREFIX_PATH.
  $env.CMAKE_PREFIX_PATH = ($c.build_dir + (if (is-windows) { ";" } else { ":" }) + ($env.CMAKE_PREFIX_PATH? | default ""))
  let jobs = (link-jobs)
  print $"configure: ($jobs) parallel link jobs"
  (^cmake ($c.llvm_src | path join "llvm") -G Ninja
    $"-DCMAKE_BUILD_TYPE=Release"
    $"-DCMAKE_INSTALL_PREFIX=($c.prefix)"
    "-DCMAKE_C_COMPILER_LAUNCHER=ccache"
    "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
    # scope: full standalone LLVM toolchain (design §3); AMDGPU absent
    # until conda-forge ROCm >=7.2 (design §4)
    "-DLLVM_TARGETS_TO_BUILD=X86;NVPTX"
    "-DLLVM_ENABLE_PROJECTS=clang;lld;lldb;clang-tools-extra;bolt;polly;openmp"
    "-DLLVM_ENABLE_RUNTIMES=compiler-rt"
    "-DLLVM_BUILD_TOOLS=ON"
    "-DCLANG_BUILD_TOOLS=ON"
    "-DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF"
    "-DLLVM_BUILD_LLVM_DYLIB=ON"
    "-DLLVM_LINK_LLVM_DYLIB=ON"
    "-DLLVM_ENABLE_RTTI=ON"
    "-DLLVM_ENABLE_EH=ON"
    # AdaptiveCpp linked into the LLVM tools
    "-DLLVM_EXTERNAL_PROJECTS=AdaptiveCpp"
    $"-DLLVM_EXTERNAL_ADAPTIVECPP_SOURCE_DIR=($c.acpp_src)"
    "-DLLVM_ADAPTIVECPP_LINK_INTO_TOOLS=ON"
    # backends: generic SSCP only; ROCm off (design §4)
    "-DWITH_CUDA_BACKEND=ON"
    "-DWITH_LEVEL_ZERO_BACKEND=ON"
    "-DWITH_OPENCL_BACKEND=ON"
    "-DWITH_CPU_BACKEND=ON"
    "-DWITH_ACCELERATED_CPU=ON"
    "-DWITH_ROCM_BACKEND=OFF"
    "-DACPP_COMPILER_FEATURE_PROFILE=full"
    # CUDA: precise conda-forge pieces (cudart/driver stubs + libdevice)
    $"-DCUDAToolkit_ROOT=($c.prefix)"
    $"-DCUDA_TOOLKIT_ROOT_DIR=($c.prefix)"
    $"-DCUDA_DEVICE_LIBS_PATH=($c.prefix)/nvvm/libdevice"
    # OpenCL: ICD loader from conda-forge; kernel headers from pinned checkouts
    $"-DOpenCL_LIBRARY=($c.prefix)/lib/libOpenCL.so"
    $"-DOpenCL_INCLUDE_DIR=($c.prefix)/include"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-HEADERS=($c.oclh_src)"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-CXX-HEADERS=($c.oclhpp_src)"
    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
    # SPIRV translator: pinned local source (see patch-spirv-redirect)
    $"-DLLVMSPIRV_SOURCE_DIR=($c.spirv_src)"
    # openmp: libomp built for completeness but NOT packaged (conda-forge
    # llvm-openmp provides it at runtime — design §5)
    "-DOPENMP_ENABLE_LIBOMPTARGET=OFF"
    # lldb: python scripting on, heavier optional deps off
    "-DLLDB_ENABLE_PYTHON=ON"
    "-DLLDB_ENABLE_LIBEDIT=OFF"
    "-DLLDB_ENABLE_CURSES=OFF"
    "-DLLDB_ENABLE_LZMA=OFF"
    "-DLLDB_ENABLE_LIBXML2=OFF"
    # compiler-rt: builtins only
    "-DCOMPILER_RT_BUILD_BUILTINS=ON"
    "-DCOMPILER_RT_BUILD_SANITIZERS=OFF"
    "-DCOMPILER_RT_BUILD_XRAY=OFF"
    "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF"
    "-DCOMPILER_RT_BUILD_PROFILE=OFF"
    "-DCOMPILER_RT_BUILD_MEMPROF=OFF"
    "-DCOMPILER_RT_BUILD_ORC=OFF"
    # build performance
    $"-DLLVM_PARALLEL_LINK_JOBS=($jobs)"
    "-DLLVM_INCLUDE_BENCHMARKS=OFF"
    "-DLLVM_INCLUDE_EXAMPLES=OFF"
    "-DLLVM_INCLUDE_TESTS=OFF"
    # conda host libs
    "-DLLVM_ENABLE_ZLIB=FORCE_ON"
    "-DLLVM_ENABLE_ZSTD=FORCE_ON"
    "-DLLVM_ENABLE_LIBXML2=FORCE_ON"
    "-DLLVM_ENABLE_LIBEDIT=OFF"
    "-DLLVM_DYLIB_SYMBOL_VERSIONING=ON"
    # relocatable rpaths
    "-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib"
    $"-DCMAKE_BUILD_RPATH=($c.build_dir)/lib"
    # conda triple
    "-DLLVM_HOST_TRIPLE=x86_64-conda-linux-gnu"
    "-DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-conda-linux-gnu"
    "-DCMAKE_EXE_LINKER_FLAGS_INIT=-pthread"
    "-DCMAKE_SHARED_LINKER_FLAGS_INIT=-pthread"
    "-DCMAKE_MODULE_LINKER_FLAGS_INIT=-pthread"
    "-B" $c.build_dir)
}

def build [] {
  let c = (config)
  ^cmake --build $c.build_dir --parallel (cpu-count)
}

def install [] {
  let c = (config)
  ^cmake --install $c.build_dir
  # unversioned lib symlinks conflict with other conda packages' dev files
  for f in [libLLVM.so libLTO.so libRemarks.so libclang.so libclang-cpp.so] {
    let p = ($c.prefix | path join "lib" $f)
    if ($p | path exists) { rm $p }
  }
  # licenses for about.license_file (recipes reference licenses/…)
  let lic = ($env.SRC_DIR | path join "licenses")
  mkdir $lic
  cp ($c.llvm_src | path join "LICENSE.TXT") ($lic | path join "LLVM-LICENSE.txt")
  cp ($c.acpp_src | path join "LICENSE") ($lic | path join "AdaptiveCpp-LICENSE.txt")
  # runtime activation script (packaged only by acpp-runtime's file carve)
  let act = ($c.prefix | path join "etc" "conda" "activate.d")
  mkdir $act
  cp ($env.SRC_DIR | path join "shared" "activation" "acpp-runtime-activate.sh") $act
}

def main [] {
  print "subcommands: toolchain"
}

def "main toolchain" [] {
  fetch-sources
  configure
  build
  install
  ^ccache --show-stats
  print "toolchain build+install complete"
}
