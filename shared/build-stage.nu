# build-stage.nu — the ONE LLVM+AdaptiveCpp build behind every package output.
#
# Sources are fetched by rattler-build into the work dir; the staging cache
# snapshots prefix+work_dir so the carving outputs never recompile. The CMake
# binary dir lives OUTSIDE the work dir so compile-command paths stay stable
# for ccache and a staging-cache miss can still reuse objects.
#
# Linux and Windows differ materially (upstream AdaptiveCpp only supports
# clang-cl on Windows, there is no LLVM dylib there, and the backend set is
# smaller), so the CMake argument list is assembled per platform.

def is-windows [] { $nu.os-info.name == "windows" }

def cpu-count [] { $env.CPU_COUNT? | default (sys cpu | length | into string) | into int }

# Link jobs are memory-bound, not CPU-bound: LLVM links are ~1-2 GB each.
def link-jobs [] {
  let mem_gb = (((sys mem | get total | into int) / 1073741824) | math round)
  [1 ([($mem_gb // 4) (cpu-count)] | math min)] | math max
}

def common-args [src: string, prefix: string, build: string] {
  [
    "-DCMAKE_BUILD_TYPE=Release"
    $"-DCMAKE_INSTALL_PREFIX=($prefix)"
    "-DCMAKE_C_COMPILER_LAUNCHER=ccache"
    "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
    "-DLLVM_TARGETS_TO_BUILD=X86;NVPTX"
    "-DLLVM_ENABLE_RUNTIMES=compiler-rt"
    "-DLLVM_BUILD_TOOLS=ON"
    "-DCLANG_BUILD_TOOLS=ON"
    "-DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF"
    "-DLLVM_ENABLE_RTTI=ON"
    "-DLLVM_ENABLE_EH=ON"
    "-DLLVM_EXTERNAL_PROJECTS=AdaptiveCpp"
    $"-DLLVM_EXTERNAL_ADAPTIVECPP_SOURCE_DIR=($src)/AdaptiveCpp"
    "-DLLVM_ADAPTIVECPP_LINK_INTO_TOOLS=ON"
    "-DWITH_CUDA_BACKEND=ON"
    "-DWITH_CPU_BACKEND=ON"
    "-DWITH_ACCELERATED_CPU=ON"
    "-DWITH_ROCM_BACKEND=OFF"
    "-DACPP_COMPILER_FEATURE_PROFILE=full"
    $"-DCUDAToolkit_ROOT=($prefix)"
    $"-DCUDA_TOOLKIT_ROOT_DIR=($prefix)"
    $"-DLLVMSPIRV_SOURCE_DIR=($src)/SPIRV-LLVM-Translator"
    "-DOPENMP_ENABLE_LIBOMPTARGET=OFF"
    "-DCOMPILER_RT_BUILD_BUILTINS=ON"
    "-DCOMPILER_RT_BUILD_SANITIZERS=OFF"
    "-DCOMPILER_RT_BUILD_XRAY=OFF"
    "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF"
    "-DCOMPILER_RT_BUILD_PROFILE=OFF"
    "-DCOMPILER_RT_BUILD_MEMPROF=OFF"
    "-DCOMPILER_RT_BUILD_ORC=OFF"
    $"-DLLVM_PARALLEL_LINK_JOBS=(link-jobs)"
    "-DLLVM_INCLUDE_BENCHMARKS=OFF"
    "-DLLVM_INCLUDE_EXAMPLES=OFF"
    "-DLLVM_INCLUDE_TESTS=OFF"
    "-DLLVM_ENABLE_ZLIB=FORCE_ON"
    "-DLLVM_ENABLE_ZSTD=FORCE_ON"
  ]
}

def linux-args [src: string, prefix: string] {
  [
    # lldb/bolt/polly/clang-tools-extra are linux-only in this suite
    "-DLLVM_ENABLE_PROJECTS=clang;lld;lldb;clang-tools-extra;bolt;polly;openmp"
    # One dylib every tool links against — the seam the whole partition rests on
    "-DLLVM_BUILD_LLVM_DYLIB=ON"
    "-DLLVM_LINK_LLVM_DYLIB=ON"
    "-DLLVM_DYLIB_SYMBOL_VERSIONING=ON"
    "-DWITH_LEVEL_ZERO_BACKEND=ON"
    "-DWITH_OPENCL_BACKEND=ON"
    $"-DCUDA_DEVICE_LIBS_PATH=($prefix)/nvvm/libdevice"
    $"-DOpenCL_LIBRARY=($prefix)/lib/libOpenCL.so"
    $"-DOpenCL_INCLUDE_DIR=($prefix)/include"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-HEADERS=($src)/OpenCL-Headers"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-CXX-HEADERS=($src)/OpenCL-CLHPP"
    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
    "-DLLVM_ENABLE_LIBXML2=FORCE_ON"
    "-DLLVM_ENABLE_LIBEDIT=OFF"
    "-DLLDB_ENABLE_PYTHON=ON"
    "-DLLDB_ENABLE_LIBEDIT=OFF"
    "-DLLDB_ENABLE_CURSES=OFF"
    "-DLLDB_ENABLE_LZMA=OFF"
    "-DLLDB_ENABLE_LIBXML2=OFF"
    "-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib"
    "-DLLVM_HOST_TRIPLE=x86_64-conda-linux-gnu"
    "-DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-conda-linux-gnu"
    "-DCMAKE_EXE_LINKER_FLAGS_INIT=-pthread"
    "-DCMAKE_SHARED_LINKER_FLAGS_INIT=-pthread"
    "-DCMAKE_MODULE_LINKER_FLAGS_INIT=-pthread"
  ]
}

def windows-args [src: string, libprefix: string] {
  [
    # Mirrors AdaptiveCpp's own windows-acppllvm.yml: no lldb/bolt/polly.
    # clang-tools-extra is added on top (LLVM builds it fine on Windows and it
    # keeps acpp-tools at parity with the linux suite).
    "-DLLVM_ENABLE_PROJECTS=clang;lld;clang-tools-extra;openmp"
    # Windows has no libLLVM dylib — tools link the static libs instead, which
    # is why the win file partition differs from linux by construction.
    "-DLLVM_BUILD_LLVM_DYLIB=OFF"
    "-DLLVM_LINK_LLVM_DYLIB=OFF"
    # Level Zero and OpenCL loaders BOTH ship for win-64 (level-zero-devel,
    # khronos-opencl-icd-loader), so the Intel backends are built here too.
    # Upstream's CI disables OpenCL on Windows but the docs never say it
    # cannot work; if this proves wrong, CI is where we find out.
    "-DWITH_LEVEL_ZERO_BACKEND=ON"
    "-DWITH_OPENCL_BACKEND=ON"
    $"-DOpenCL_LIBRARY=($libprefix)/lib/OpenCL.lib"
    $"-DOpenCL_INCLUDE_DIR=($libprefix)/include"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-HEADERS=($src)/OpenCL-Headers"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-CXX-HEADERS=($src)/OpenCL-CLHPP"
    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
    "-DLLVM_TOOL_BUGPOINT_BUILD=OFF"
    "-DLLVM_HOST_TRIPLE=x86_64-pc-windows-msvc"
    "-DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-pc-windows-msvc"
    # AdaptiveCpp still uses the DEPRECATED FindCUDA module
    # (`find_package(CUDA QUIET)`), which on Windows searches a
    # <root>/lib/x64 toolkit layout. conda ships the import libs flat in
    # Library/lib, so detection silently fails and acpp aborts with
    # "CUDA was not found". Seed the cache entries with the real paths so
    # the find_* calls short-circuit instead of guessing.
    $"-DCUDA_TOOLKIT_ROOT_DIR=($libprefix)"
    $"-DCUDA_NVCC_EXECUTABLE=($libprefix)/bin/nvcc.exe"
    $"-DCUDA_TOOLKIT_INCLUDE=($libprefix)/include"
    $"-DCUDA_CUDART_LIBRARY=($libprefix)/lib/cudart.lib"
    $"-DCUDA_DEVICE_LIBS_PATH=($libprefix)/nvvm/libdevice"
  ]
}

def main [] {
  # Empty values forwarded from the recipe env mean "unset" — hide them so the
  # tools fall back to their own defaults instead of seeing "".
  for v in [CCACHE_DIR CCACHE_MAXSIZE CCACHE_BASEDIR CCACHE_NOHASHDIR ACPP_BUILD_DIR] {
    if ($env | get -o $v | default "") == "" { hide-env --ignore-errors $v }
  }
  let src = $env.SRC_DIR
  # Conda's Windows layout puts headers/libs/binaries under %PREFIX%\Library,
  # so that — not $PREFIX — is the install prefix and the dependency root on
  # Windows. On Linux the two are the same.
  let prefix = (if (is-windows) { $env.LIBRARY_PREFIX? | default ($env.PREFIX | path join "Library") } else { $env.PREFIX })
  let build = ($env.ACPP_BUILD_DIR? | default ($src | path join ".." "build_dir"))
  mkdir $build

  let sep = (if (is-windows) { ";" } else { ":" })
  $env.CMAKE_PREFIX_PATH = ($build + $sep + ($env.CMAKE_PREFIX_PATH? | default ""))
  $env.CCACHE_COMPILERCHECK = "content"

  if (is-windows) {
    # FindCUDA consults %CUDA_PATH% before anything else on Windows.
    $env.CUDA_PATH = $prefix
    # conda's win activation exports a Visual Studio generator; leaving those
    # set makes CMake reject `-G Ninja` ("does not support platform/toolset
    # specification").
    hide-env --ignore-errors CMAKE_GENERATOR
    hide-env --ignore-errors CMAKE_GENERATOR_PLATFORM
    hide-env --ignore-errors CMAKE_GENERATOR_TOOLSET
  }

  let args = ((common-args $src $prefix $build)
    | append (if (is-windows) { (windows-args $src $prefix) } else { (linux-args $src $prefix) }))

  ^cmake ($src | path join "llvm-project" "llvm") -G Ninja ...$args -B $build

  if (is-windows) {
    ^cmake --build $build --parallel (cpu-count)
  } else {
    # libLLVM.so must exist BEFORE AdaptiveCpp's SPIRV-LLVM-Translator
    # ExternalProject builds: its inner cmake links the file directly, so the
    # outer ninja has no rule for it and high job counts race ahead of the link
    # (invisible at -j16, fatal at -j64). Windows has no dylib, so no race.
    ^cmake --build $build --target LLVM --parallel (cpu-count)
    ^cmake --build $build --parallel (cpu-count)
  }

  cd $build
  ^cmake --install $build

  if not (is-windows) {
    # Unversioned .so symlinks are dev-package files elsewhere in conda; the
    # versioned sonames are what the runtime needs.
    for f in [libLLVM.so libLTO.so libRemarks.so libclang.so libclang-cpp.so] {
      let p = ($prefix | path join "lib" $f)
      if ($p | path exists) { rm $p }
    }
    # Triple-prefixed driver names, matching the conda-forge clang_impl layout
    if not (($prefix | path join "bin" "x86_64-conda-linux-gnu-clang") | path exists) {
      ^ln -s clang ($prefix | path join "bin" "x86_64-conda-linux-gnu-clang")
      ^ln -s clang++ ($prefix | path join "bin" "x86_64-conda-linux-gnu-clang++")
      ^ln -s clang-cpp ($prefix | path join "bin" "x86_64-conda-linux-gnu-clang-cpp")
    }
    let act = ($prefix | path join "etc" "conda" "activate.d")
    mkdir $act
    cp ($src | path join "shared" "activation" "acpp-runtime-activate.sh") $act
  }

  ^ccache --show-stats
}
