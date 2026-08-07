# build-stage.nu — staging-experiment build: pure rattler-build semantics.
# Sources fetched by rattler into the work dir; build runs in-tree
# (work-dir cached by the staging cache for inheriting outputs);
# NO stable-symlink machinery — $PREFIX is baked directly and relocates
# naturally because every output carves the SAME build's prefix.
def cpu-count [] { $env.CPU_COUNT? | default (sys cpu | length | into string) | into int }

def main [] {
  # empty CCACHE_DIR forwarded from recipe env => fall back to ccache defaults
  if ($env.CCACHE_DIR? | default "") == "" { hide-env --ignore-errors CCACHE_DIR }
  let src = $env.SRC_DIR
  let prefix = $env.PREFIX
  let build = ($src | path join "build")
  mkdir $build
  let mem_gb = ((open /proc/meminfo | lines | first | parse "MemTotal:{kb} kB" | get kb.0 | str trim | into int) / 1048576 | math round)
  let jobs = ([1 ([($mem_gb // 4) (cpu-count)] | math min)] | math max)
  $env.CMAKE_PREFIX_PATH = ($build + ":" + ($env.CMAKE_PREFIX_PATH? | default ""))
  $env.CCACHE_COMPILERCHECK = "content"
  (^cmake ($src | path join "llvm-project" "llvm") -G Ninja
    "-DCMAKE_BUILD_TYPE=Release"
    $"-DCMAKE_INSTALL_PREFIX=($prefix)"
    "-DCMAKE_C_COMPILER_LAUNCHER=ccache"
    "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
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
    "-DLLVM_EXTERNAL_PROJECTS=AdaptiveCpp"
    $"-DLLVM_EXTERNAL_ADAPTIVECPP_SOURCE_DIR=($src)/AdaptiveCpp"
    "-DLLVM_ADAPTIVECPP_LINK_INTO_TOOLS=ON"
    "-DWITH_CUDA_BACKEND=ON"
    "-DWITH_LEVEL_ZERO_BACKEND=ON"
    "-DWITH_OPENCL_BACKEND=ON"
    "-DWITH_CPU_BACKEND=ON"
    "-DWITH_ACCELERATED_CPU=ON"
    "-DWITH_ROCM_BACKEND=OFF"
    "-DACPP_COMPILER_FEATURE_PROFILE=full"
    $"-DCUDAToolkit_ROOT=($prefix)"
    $"-DCUDA_TOOLKIT_ROOT_DIR=($prefix)"
    $"-DCUDA_DEVICE_LIBS_PATH=($prefix)/nvvm/libdevice"
    $"-DOpenCL_LIBRARY=($prefix)/lib/libOpenCL.so"
    $"-DOpenCL_INCLUDE_DIR=($prefix)/include"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-HEADERS=($src)/OpenCL-Headers"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-CXX-HEADERS=($src)/OpenCL-CLHPP"
    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
    $"-DLLVMSPIRV_SOURCE_DIR=($src)/SPIRV-LLVM-Translator"
    "-DOPENMP_ENABLE_LIBOMPTARGET=OFF"
    "-DLLDB_ENABLE_PYTHON=ON"
    "-DLLDB_ENABLE_LIBEDIT=OFF"
    "-DLLDB_ENABLE_CURSES=OFF"
    "-DLLDB_ENABLE_LZMA=OFF"
    "-DLLDB_ENABLE_LIBXML2=OFF"
    "-DCOMPILER_RT_BUILD_BUILTINS=ON"
    "-DCOMPILER_RT_BUILD_SANITIZERS=OFF"
    "-DCOMPILER_RT_BUILD_XRAY=OFF"
    "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF"
    "-DCOMPILER_RT_BUILD_PROFILE=OFF"
    "-DCOMPILER_RT_BUILD_MEMPROF=OFF"
    "-DCOMPILER_RT_BUILD_ORC=OFF"
    $"-DLLVM_PARALLEL_LINK_JOBS=($jobs)"
    "-DLLVM_INCLUDE_BENCHMARKS=OFF"
    "-DLLVM_INCLUDE_EXAMPLES=OFF"
    "-DLLVM_INCLUDE_TESTS=OFF"
    "-DLLVM_ENABLE_ZLIB=FORCE_ON"
    "-DLLVM_ENABLE_ZSTD=FORCE_ON"
    "-DLLVM_ENABLE_LIBXML2=FORCE_ON"
    "-DLLVM_ENABLE_LIBEDIT=OFF"
    "-DLLVM_DYLIB_SYMBOL_VERSIONING=ON"
    "-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib"
    "-DLLVM_HOST_TRIPLE=x86_64-conda-linux-gnu"
    "-DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-conda-linux-gnu"
    "-DCMAKE_EXE_LINKER_FLAGS_INIT=-pthread"
    "-DCMAKE_SHARED_LINKER_FLAGS_INIT=-pthread"
    "-DCMAKE_MODULE_LINKER_FLAGS_INIT=-pthread"
    "-B" $build)
  ^cmake --build $build --parallel (cpu-count)
  cd $build
  ^cmake --install $build
  for f in [libLLVM.so libLTO.so libRemarks.so libclang.so libclang-cpp.so] {
    let p = ($prefix | path join "lib" $f)
    if ($p | path exists) { rm $p }
  }
  if not (($prefix | path join "bin" "x86_64-conda-linux-gnu-clang") | path exists) {
    ^ln -s clang ($prefix | path join "bin" "x86_64-conda-linux-gnu-clang")
    ^ln -s clang++ ($prefix | path join "bin" "x86_64-conda-linux-gnu-clang++")
    ^ln -s clang-cpp ($prefix | path join "bin" "x86_64-conda-linux-gnu-clang-cpp")
  }
  let act = ($prefix | path join "etc" "conda" "activate.d")
  mkdir $act
  cp ($src | path join "shared" "activation" "acpp-runtime-activate.sh") $act
  ^ccache --show-stats
}
