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
    # LLVM_ENABLE_RUNTIMES=compiler-rt is LINUX-ONLY (see linux-args): the
    # runtimes bootstrap exists to keep conda's gcc from building the
    # sanitizer runtimes (Jack's Option A). On win the host compiler is
    # already clang-cl, so compiler-rt rides LLVM_ENABLE_PROJECTS there
    # instead — the bootstrap child buys nothing and its second compiler
    # discovery never worked (runs 31350122413/31351719706; upstream
    # AdaptiveCpp's own windows-acppllvm.yml uses the projects path too).
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
    # compiler-rt: builtins plus the sanitizer runtimes (phase-3 ruling [B]).
    #
    # These were all OFF, which made the toolchain a NON-drop-in replacement:
    # `clang -fsanitize=address` would fail to link against a runtime we never
    # built. Since the toolchain's whole promise is that it can stand in for a
    # conda-forge clang, the sanitizer runtimes ship, in acpp-compiler-rt.
    #
    # Per-component rather than a blanket ON because the components have
    # genuinely different platform support; the per-platform arg sets below add
    # the ones that are linux-only.
    "-DCOMPILER_RT_BUILD_BUILTINS=ON"
    "-DCOMPILER_RT_BUILD_SANITIZERS=ON"
    "-DCOMPILER_RT_BUILD_PROFILE=ON"
    "-DCOMPILER_RT_BUILD_LIBFUZZER=ON"
    $"-DLLVM_PARALLEL_LINK_JOBS=(link-jobs)"
    "-DLLVM_INCLUDE_BENCHMARKS=OFF"
    "-DLLVM_INCLUDE_EXAMPLES=OFF"
    "-DLLVM_INCLUDE_TESTS=OFF"
    "-DLLVM_ENABLE_ZLIB=FORCE_ON"
    "-DLLVM_ENABLE_ZSTD=FORCE_ON"
  ]
}

# Where the conda toolchain lives, for the runtimes sub-build. See the note in
# linux-args. Returns [] when neither can be located, so the build fails with
# the real compiler error rather than a confusing empty --sysroot=.
def linux-triple [] {
  # The build is always native (pseudo-cross): the runner's arch IS the
  # target arch, and the conda triplet follows it.
  if $nu.os-info.arch == "aarch64" { "aarch64-conda-linux-gnu" } else { "x86_64-conda-linux-gnu" }
}

def is-darwin [] { $nu.os-info.name == "macos" }

# macOS, FIRST CUT — OMP-only, no lldb/bolt (bolt has no darwin port), no
# compiler-rt (the sanitizer story is its own pass), no GPU backends (Metal
# comes later). Apple triples are inferred natively — no host/target triple
# overrides, no sysroot machinery: the activation's CMAKE_ARGS carries
# CMAKE_OSX_SYSROOT and the deployment target.
def darwin-args [src: string, prefix: string] {
  [
    "-DLLVM_ENABLE_PROJECTS=clang;lld;clang-tools-extra;openmp"
    "-DLLVM_BUILD_LLVM_DYLIB=ON"
    "-DLLVM_LINK_LLVM_DYLIB=ON"
    "-DWITH_CUDA_BACKEND=OFF"
    "-DWITH_LEVEL_ZERO_BACKEND=OFF"
    "-DWITH_OPENCL_BACKEND=OFF"
    "-DWITH_ROCM_BACKEND=OFF"
    "-DLLVM_TARGETS_TO_BUILD=AArch64"
    "-DCOMPILER_RT_BUILD_BUILTINS=OFF"
    "-DCOMPILER_RT_BUILD_SANITIZERS=OFF"
    "-DCOMPILER_RT_BUILD_PROFILE=OFF"
    "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF"
    "-DCMAKE_INSTALL_RPATH=@loader_path/../lib"
  ]
}

def conda-toolchain-args [] {
  let sysroot = ($env.CONDA_BUILD_SYSROOT? | default "")
  let bp = ($env.BUILD_PREFIX? | default "")
  # conda's own layout when CONDA_BUILD_SYSROOT is not exported.
  let derived = (if $bp != "" { [$bp (linux-triple) "sysroot"] | path join } else { "" })
  let chosen = (if ($sysroot != "" and ($sysroot | path exists)) {
    $sysroot
  } else if ($derived != "" and ($derived | path exists)) {
    $derived
  } else {
    ""
  })

  if $chosen == "" {
    print "WARNING: no conda sysroot found (CONDA_BUILD_SYSROOT unset and BUILD_PREFIX layout absent); compiler-rt will use system headers"
    return []
  }
  print $"compiler-rt runtimes toolchain: sysroot=($chosen) gcc-toolchain=($bp)"

  # PSEUDO-CROSS, done the way LLVM 20's own machinery expects (verified
  # against llvm/runtimes/CMakeLists.txt + LLVMExternalProjectUtils.cmake in
  # the exact source tree we build):
  #
  #   * The runtimes are configured by a SEPARATE child cmake driven by the
  #     just-built clang. That child receives compilers, LLVM paths and
  #     LLVM_HOST_TRIPLE from the outer build — but NEVER the outer
  #     CMAKE_{C,CXX}_FLAGS. Its flags are seeded from the ENVIRONMENT
  #     (CFLAGS/CXXFLAGS), which carry conda's gcc-shaped flags. main()
  #     therefore STRIPS those from the env and passes them to the OUTER
  #     configure explicitly — outer build unchanged, child build clean.
  #   * Everything the child needs beyond that goes through
  #     RUNTIMES_CMAKE_ARGS, verbatim (llvm/runtimes/CMakeLists.txt:275):
  #       --sysroot        finds the C library headers  (glibc 2.28 —
  #                        redistributability floor)
  #       --gcc-toolchain  finds the C++ stdlib headers (libstdc++)
  #       COMPILER_TARGET  clang's --target; must match the sysroot triple
  #                        (HowToCrossCompileLLVM), and is what makes the
  #                        pseudo-cross EXPLICIT instead of accidental
  #   * CMAKE_FIND_ROOT_PATH* mirrors the compiler activation package's own
  #     CMAKE_ARGS (which the child cannot inherit: its compiler is the
  #     just-built clang, and env CFLAGS/CXXFLAGS are stripped), so the
  #     child's find_library/find_path see the sysroot the same way the
  #     outer configure does. The embedded list separator is `|`: the child
  #     ExternalProject declares LIST_SEPARATOR | and LLVM's own forwarding
  #     rewrites `;` to `|` for exactly this case
  #     (LLVMExternalProjectUtils.cmake).
  #   * Deliberately NOT set: CMAKE_SYSTEM_NAME=Linux — it flips the child
  #     into full cross mode and changes find semantics wholesale, which the
  #     explicit FIND_ROOT settings above make unnecessary.
  let triple = (linux-triple)
  let flags = $"--sysroot=($chosen) --gcc-toolchain=($bp)"
  let host_prefix = ($env.PREFIX? | default "")
  [
    ([
      $"-DCMAKE_SYSROOT=($chosen)"
      $"-DCMAKE_C_COMPILER_TARGET=($triple)"
      $"-DCMAKE_CXX_COMPILER_TARGET=($triple)"
      $"-DCMAKE_ASM_COMPILER_TARGET=($triple)"
      $"-DCMAKE_C_FLAGS=($flags)"
      $"-DCMAKE_CXX_FLAGS=($flags)"
      "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER"
      "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY"
      "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY"
      $"-DCMAKE_FIND_ROOT_PATH=($host_prefix)|($chosen)"
    ] | str join ";" | $"-DRUNTIMES_CMAKE_ARGS=($in)")
  ]
}

# LINUX ONLY: the outer configure must receive the conda flags EXPLICITLY once
# main() strips them from the env (see conda-toolchain-args). Replicates
# cmake's own env-seeding semantics: CFLAGS->CMAKE_C_FLAGS,
# CXXFLAGS->CMAKE_CXX_FLAGS, LDFLAGS->all three *_LINKER_FLAGS. The linux
# -pthread that previously rode in via *_LINKER_FLAGS_INIT is folded in here
# (an explicit cache value overrides _INIT, so keeping both would have
# silently dropped it).
#
# On WINDOWS this returns NOTHING, deliberately. An explicit -DCMAKE_CXX_FLAGS
# on the command line pre-seeds the cache and suppresses CMake's Windows-MSVC
# platform defaults (/DWIN32 /D_WINDOWS /EHsc) — and those defaults are
# LOAD-BEARING: AdaptiveCpp guards its POSIX includes with `#ifndef WIN32`
# (plain WIN32, NOT the compiler builtin _WIN32; the macro only exists because
# CMake's default flags define it), so clobbering them broke omp_queue.cpp
# with "'unistd.h' file not found" (run 31350122413). Emitting no flag args
# lets CMake initialize from its platform *_INIT values; env CFLAGS/CXXFLAGS
# are stripped by main() before configure, so nothing gnu-shaped appends, and
# env LDFLAGS (kept) appends to /machine:x64 exactly as in the proven-green
# pre-override builds.
def outer-flag-args [] {
  if (is-windows) { return [] }
  let cflags = ($env.CFLAGS? | default "")
  let cxxflags = ($env.CXXFLAGS? | default "")
  let base_ld = ($env.LDFLAGS? | default "")
  let ldflags = ([$base_ld "-pthread"] | str join " " | str trim)
  [
    $"-DCMAKE_C_FLAGS=($cflags)"
    $"-DCMAKE_CXX_FLAGS=($cxxflags)"
    $"-DCMAKE_EXE_LINKER_FLAGS=($ldflags)"
    $"-DCMAKE_SHARED_LINKER_FLAGS=($ldflags)"
    $"-DCMAKE_MODULE_LINKER_FLAGS=($ldflags)"
  ]
}

# Dump the runtimes/builtins child-configure failure evidence into the CI
# log. The console only ever shows "ABI info - failed"; the WHY lives in the
# children's configure logs, which no runner surfaces on its own (this cost
# us a blind red on win-64). Two hard-won details:
# - CMake >= 3.26 does NOT write CMakeError.log anymore — try_compile
#   evidence (full command line + stderr per failed check) lives in
#   CMakeFiles/CMakeConfigureLog.yaml. Globbing for CMakeError.log finds
#   nothing on the cmake 4.4 runners.
# - nushell's glob parser treats backslash as an escape character, so a
#   Windows path from `path join` makes `glob` ERROR OUT (run 31351719706
#   died exactly here, masking the evidence it was built to surface).
#   Normalize to forward slashes before globbing.
def dump-runtimes-logs [build: string] {
  let root = ($build | path join "runtimes" | str replace --all '\' '/')
  for f in (glob $"($root)/**/CMakeConfigureLog.yaml") {
    print $"===== child configure evidence: ($f) ====="
    let text = (open --raw $f | lines)
    # ABI detection is among the FIRST entries (usually where the rot starts);
    # the tail carries the last failed checks. Print both ends.
    $text | first 500 | str join "\n" | print
    print $"===== ... tail of ($f) ====="
    $text | last 200 | str join "\n" | print
  }
}

def linux-args [src: string, prefix: string] {
  ([
    # lldb/bolt/polly/clang-tools-extra are linux-only in this suite
    "-DLLVM_ENABLE_PROJECTS=clang;lld;lldb;clang-tools-extra;bolt;polly;openmp"
    # Runtimes bootstrap (just-built clang builds compiler-rt) is the linux
    # path ONLY — the host compiler here is conda gcc, which must not build
    # the sanitizer runtimes (Jack's Option A; conda-forge's standalone-gcc
    # shape is the approach LLVM needed many versions ago). Proven green
    # with the pseudo-cross args below.
    "-DLLVM_ENABLE_RUNTIMES=compiler-rt"
    # compiler-rt components that upstream supports on linux but not on
    # Windows. XRay has no Windows port at all; MemProf and ORC are
    # linux-first and not built by conda-forge's own Windows clang either.
    "-DCOMPILER_RT_BUILD_XRAY=ON"
    "-DCOMPILER_RT_BUILD_MEMPROF=ON"
    "-DCOMPILER_RT_BUILD_ORC=ON"
    # One dylib every tool links against — the seam the whole partition rests on
    "-DLLVM_BUILD_LLVM_DYLIB=ON"
    "-DLLVM_LINK_LLVM_DYLIB=ON"
    "-DLLVM_DYLIB_SYMBOL_VERSIONING=ON"
    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
    "-DLLVM_ENABLE_LIBXML2=FORCE_ON"
    "-DLLVM_ENABLE_LIBEDIT=OFF"
    "-DLLDB_ENABLE_PYTHON=ON"
    "-DLLDB_ENABLE_LIBEDIT=OFF"
    "-DLLDB_ENABLE_CURSES=OFF"
    "-DLLDB_ENABLE_LZMA=OFF"
    "-DLLDB_ENABLE_LIBXML2=OFF"
    "-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib"
    $"-DLLVM_HOST_TRIPLE=(linux-triple)"
    $"-DLLVM_DEFAULT_TARGET_TRIPLE=(linux-triple)"
    # -pthread now folded into outer-flag-args (explicit CMAKE_*_LINKER_FLAGS
    # override *_INIT, so the old _INIT lines would have been silently dropped)
  ] ++ (if $nu.os-info.arch == "aarch64" { linux-arm-backend-args } else { linux-x86-backend-args $src $prefix })
    ++ (conda-toolchain-args))
}

# x86-64: the full backend set.
def linux-x86-backend-args [src: string, prefix: string] {
  [
    "-DWITH_LEVEL_ZERO_BACKEND=ON"
    "-DWITH_OPENCL_BACKEND=ON"
    # ROCm: the TheRock core tarball is a BUILD input — ROCM_PATH points into
    # the extracted source tree so acpp's find_* succeed; the runtime subset
    # is deployed into the prefix post-install (see the rocm-deploy step) and
    # carved into acpp-runtime-rocm. Overrides the common-args OFF (cmake:
    # last -D wins) and widens the LLVM target list — llvm-to-amdgpu JITs
    # through libLLVM's AMDGPU backend.
    "-DWITH_ROCM_BACKEND=ON"
    $"-DROCM_PATH=($src)/rocm-dist"
    # PRESET, not searched: the activation's CMAKE_ARGS confines find_library
    # and find_path to the prefix + sysroot (FIND_ROOT_PATH_MODE_*=ONLY), and
    # the ROCm tree is a work-dir input outside both roots, so its HINTS are
    # discarded (measured: "Could not find AMDHIP64_LIBRARY"). A preset cache
    # variable skips the search entirely. hsakmt is deliberately NOT preset —
    # TheRock ships it static-only (folded into hsa-runtime), so it must stay
    # NOTFOUND and the deploy skips it.
    $"-DAMDHIP64_LIBRARY=($src)/rocm-dist/lib/libamdhip64.so"
    $"-DHSARUNTIME64_LIBRARY=($src)/rocm-dist/lib/libhsa-runtime64.so"
    $"-DAMDCOMGR_LIBRARY=($src)/rocm-dist/lib/libamd_comgr.so"
    $"-DROCPROFILERREGISTER_LIBRARY=($src)/rocm-dist/lib/librocprofiler-register.so"
    $"-DHIPRTC_LIBRARY=($src)/rocm-dist/lib/libhiprtc.so"
    $"-DROCM_DEVICE_LIBS_PATH=($src)/rocm-dist/lib/llvm/amdgcn/bitcode"
    "-DLLVM_TARGETS_TO_BUILD=X86;NVPTX;AMDGPU"
    $"-DCUDA_DEVICE_LIBS_PATH=($prefix)/nvvm/libdevice"
    $"-DOpenCL_LIBRARY=($prefix)/lib/libOpenCL.so"
    $"-DOpenCL_INCLUDE_DIR=($prefix)/include"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-HEADERS=($src)/OpenCL-Headers"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-CXX-HEADERS=($src)/OpenCL-CLHPP"
  ]
}

# aarch64: OMP-ONLY by design — the CPU backend and accelerated-CPU compiler
# are the deliverable; GPU backends arrive per platform as their dependency
# stories are established. Overrides common-args' CUDA=ON (last -D wins).
def linux-arm-backend-args [] {
  [
    "-DWITH_CUDA_BACKEND=OFF"
    "-DWITH_LEVEL_ZERO_BACKEND=OFF"
    "-DWITH_OPENCL_BACKEND=OFF"
    "-DWITH_ROCM_BACKEND=OFF"
    "-DLLVM_TARGETS_TO_BUILD=AArch64"
  ]
}

def windows-args [src: string, libprefix: string, build: string] {
  [
    # compiler-rt rides LLVM_ENABLE_PROJECTS on win (Jack, 2026-08-10) — NOT
    # the runtimes bootstrap. The bootstrap's purpose (keep a wrong-family
    # host compiler from building the sanitizer runtimes) is vacuous here:
    # the host compiler IS clang-cl, pinned in the recipe to the exact LLVM
    # version being built, so projects-mode gives a version-matched clang_rt
    # with zero child-cmake machinery. The runtimes child never configured
    # on win (runs 31350122413 / 31351719706: every child try-compile failed
    # while the outer configure and the builtins child were green — two
    # generations of injected-arg fixes disproven; root-cause evidence
    # archived in the naga-labs mechanics reference). This also mirrors
    # upstream AdaptiveCpp's own windows-acppllvm.yml, which builds
    # LLVM_ENABLE_PROJECTS="clang;openmp;lld;compiler-rt" and never uses the
    # win runtimes bootstrap. lldb/bolt/polly stay linux-only;
    # clang-tools-extra is added on top for acpp-tools parity.
    "-DLLVM_ENABLE_PROJECTS=clang;lld;clang-tools-extra;openmp;compiler-rt"
    # Windows has no libLLVM dylib — tools link the static libs instead, which
    # is why the win file partition differs from linux by construction.
    "-DLLVM_BUILD_LLVM_DYLIB=OFF"
    "-DLLVM_LINK_LLVM_DYLIB=OFF"
    # See linux-args: XRay has no Windows port, and MemProf/ORC are not built
    # for Windows by conda-forge's clang either. ASan, the profile runtime and
    # libFuzzer DO support Windows and are enabled in common-args.
    "-DCOMPILER_RT_BUILD_XRAY=OFF"
    "-DCOMPILER_RT_BUILD_MEMPROF=OFF"
    "-DCOMPILER_RT_BUILD_ORC=OFF"
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
    # AdaptiveCpp probes the BUILD compiler for -mcpu=native / -march=native and
    # uses the result as a proxy for whether llc supports -mcpu=native at JIT
    # time — upstream's own comment concedes this is the wrong check ("We should
    # actually check llc/opt here!"). MSVC rejects those clang/gcc spellings, so
    # the probe fails even though the llc we ship handles -mcpu=native fine.
    # Force exactly the value the passing path yields on linux, so host JIT
    # codegen targets the user's CPU identically on both platforms.
    "-DACPP_HOST_FORCE_MCPU_TARGET=native"
    # AdaptiveCpp requires a clang-family driver (it uses GCC/Clang builtin
    # atomics that MSVC lacks), but we deliberately do NOT pull the
    # clang_win-64 activation package, which is only ever built against
    # vs2022/vs2019 and would force the VS year backwards. Instead the plain
    # `clang` package supplies clang-cl and the vs2026 activation supplies the
    # MSVC headers/libs/SDK that clang-cl targets.
    "-DCMAKE_C_COMPILER=clang-cl"
    "-DCMAKE_CXX_COMPILER=clang-cl"
    # OpenCL-CLHPP defaults BUILD_EXAMPLES and BUILD_DOCS to ON. Pulled in via
    # FetchContent, its examples inherit LLVM's exceptions-disabled flags and
    # fail under clang-cl ("cannot use 'throw' with exceptions disabled"). We
    # only consume its headers, so skip both. (Harmless on linux, where gcc
    # builds them anyway — kept win-only to avoid churning a green lane.)
    "-DBUILD_EXAMPLES=OFF"
    "-DBUILD_DOCS=OFF"
  ]
}

def main [] {
  # Empty values forwarded from the recipe env mean "unset" — hide them so the
  # tools fall back to their own defaults instead of seeing "".
  for v in [CCACHE_DIR CCACHE_MAXSIZE CCACHE_BASEDIR CCACHE_NOHASHDIR ACPP_BUILD_DIR] {
    if ($env | get -o $v | default "") == "" { hide-env --ignore-errors $v }
  }
  let src = $env.SRC_DIR

  # License-drift guard: package outputs ship the VENDORED texts from
  # shared/licenses/ (they no longer carry the big source trees), so assert
  # the vendored copies are byte-identical to the licenses in the actually
  # extracted sources. A pin bump that changes a license fails HERE, loudly,
  # instead of silently shipping stale text.
  for pair in [
    [($src | path join "shared" "licenses" "llvm-LICENSE.TXT"), ($src | path join "llvm-project" "LICENSE.TXT")]
    [($src | path join "shared" "licenses" "AdaptiveCpp-LICENSE"), ($src | path join "AdaptiveCpp" "LICENSE")]
  ] {
    if ((open --raw $pair.0 | str replace --all "\r" "") != (open --raw $pair.1 | str replace --all "\r" "")) {
      error make {msg: $"vendored license ($pair.0) differs from source tree ($pair.1) — update shared/licenses/"}
    }
  }

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

  # Capture the conda flags for the OUTER configure, then STRIP them from the
  # environment: the runtimes child cmake (spawned mid-build by ninja) seeds
  # its flags from env CFLAGS/CXXFLAGS — the pollution vector behind both the
  # linux system-header failure and the win empty-arch failure. The outer
  # build sees identical flags via outer-flag-args; the child starts clean and
  # gets exactly what RUNTIMES_CMAKE_ARGS hands it.
  let flag_args = (outer-flag-args)
  # LDFLAGS deliberately STAYS in the env: the SPIRV-translator inner
  # ExternalProject env-seeds its linker flags and NEEDS conda's -L$PREFIX/lib
  # to resolve libLLVM.so's NEEDED libs (libz/libzstd/libxml2) — stripping it
  # broke that link (run 31349005069). Linker flags were never the poison;
  # gcc-shaped COMPILE flags were, and those still get stripped below. The
  # outer configure ignores env LDFLAGS because outer-flag-args passes
  # explicit values.
  for v in [CFLAGS CXXFLAGS CPPFLAGS DEBUG_CFLAGS DEBUG_CXXFLAGS] {
    hide-env --ignore-errors $v
  }

  # The compiler activation package's own cmake argument set: triplet
  # binutils, install layout, and CMAKE_FIND_ROOT_PATH* carrying the sysroot.
  # Authoritative — passed verbatim, first, with nothing added beside it.
  # cmake only searches the sysroot when told, so without this every bare
  # find_library() misses it (acpp's vector-math detection among them).
  # Linux only: the win leg drives clang-cl + Ninja by hand, and the VS
  # activation's CMAKE_ARGS is aimed at MSVC generators.
  let activation_args = (if (is-windows) { [] } else {
    $env.CMAKE_ARGS? | default "" | split row -r '\s+' | where {|a| $a != "" }
  })

  let args = ($activation_args
    | append (common-args $src $prefix $build)
    | append $flag_args
    | append (if (is-windows) {
        (windows-args $src $prefix $build)
      } else if (is-darwin) {
        (darwin-args $src $prefix)
      } else {
        (linux-args $src $prefix)
      }))

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

  # HOLLOW-RUNTIMES GUARD: the runtimes child-configure fails SOFT — a broken
  # child compiler yields "supported architectures: <empty>" and a technically
  # green build that ships no clang_rt libs (caught only by the package
  # content test, 8 minutes later, with zero evidence). Fail HERE instead,
  # with the child's CMakeError.log dumped into the CI log.
  # NB backslashes are glob ESCAPES in nushell — normalize the joined path or
  # `glob` fails to parse on Windows (this crash ate a run's evidence).
  let rt_glob = (if (is-windows) {
    ($prefix | path join "lib" "clang" "**" "clang_rt.asan*" | str replace --all '\' '/')
  } else {
    ($prefix | path join "lib" "clang" "**" "libclang_rt.asan*")
  })
  if ((glob $rt_glob | length) == 0) {
    dump-runtimes-logs $build
    error make {msg: "compiler-rt runtimes are HOLLOW (no asan artifacts installed) — child configure evidence dumped above"}
  }

  if not (is-windows) {
    # Unversioned .so symlinks are dev-package files elsewhere in conda; the
    # versioned sonames are what the runtime needs.
    for f in [libLLVM.so libLTO.so libRemarks.so libclang.so libclang-cpp.so] {
      let p = ($prefix | path join "lib" $f)
      if ($p | path exists) { rm $p }
    }
    # NB: NO triple-prefixed driver symlinks here. They are activation-package
    # files (render-install.sh creates them); a base package carrying the
    # triplet tells the LLVM/cmake ecosystem it is in an isolated build env
    # and poisons plain runtime environments.
  } else {
  }

  # default-cpu-cxx is baked as CMAKE_CXX_COMPILER — the BUILD machine's
  # compiler, dead on every user machine. Rewrite it to the $ACPP_PATH
  # placeholder the driver expands at runtime (the mechanism default-clang
  # already uses); the compiler activation package overrides both via
  # ACPP_CPU_CXX/ACPP_CLANG with the triple-prefixed form.
  let core_json = ($prefix | path join "etc" "AdaptiveCpp" "acpp-core.json")
  if ($core_json | path exists) {
    let cpu_cxx = (if (is-windows) { "$ACPP_PATH/bin/clang++.exe" } else { "$ACPP_PATH/bin/clang++" })
    open --raw $core_json | from json | upsert "default-cpu-cxx" $cpu_cxx | to json | save -f $core_json
    print $"acpp-core.json: default-cpu-cxx -> ($cpu_cxx)"
  } else {
    error make {msg: $"acpp-core.json not found at ($core_json)"}
  }

  # ROCm runtime deploy (linux): acpp's OWN hip deployment manifest names
  # exactly what the backend needs at runtime. The ROCm tree is a BUILD
  # input (the TheRock tarball source), so those pieces are deployed into
  # the prefix here and carved into acpp-runtime-rocm. Entries already
  # inside the prefix ($ACPP_* placeholders — the backend's own files) are
  # installed normally and skipped. Symlink families are preserved: the
  # manifest names find_library's answer (the unversioned dev name) while
  # DT_NEEDED resolves the SONAME, so both must exist.
  if (not (is-windows)) and $nu.os-info.arch != "aarch64" {
    let manifest = ($prefix | path join "etc" "AdaptiveCpp" "deploy" "acpp-deployment-manifest-hip.json")
    if not ($manifest | path exists) {
      error make {msg: $"hip deployment manifest missing: ($manifest)"}
    }
    let libdir = ($prefix | path join "lib")
    for e in (open --raw $manifest | from json | transpose src dest) {
      if ($e.src | str contains "$ACPP_") { continue }
      if ($e.src | str starts-with $prefix) { continue }
      # optional components acpp probes without REQUIRED (hsakmt was folded
      # into hsa-runtime; rocprofiler-register is optional) render as
      # <VAR>-NOTFOUND when the tarball does not carry them
      if ($e.src | str contains "-NOTFOUND") { continue }
      let destdir = ([$libdir, ($e.dest | str trim -c '/')] | path join)
      mkdir $destdir
      # Stem glob, not name glob: libhiprtc.so's loader dependency is
      # libhiprtc-builtins.so.7, which only a stem-wide pattern catches.
      let pattern = (if ($e.src | str ends-with "/*") {
        $e.src
      } else {
        ($e.src | path dirname) + "/" + ($e.src | path basename | str replace -r '\.so.*$' '') + "*"
      })
      let matches = (glob $pattern)
      if ($matches | is-empty) { error make {msg: $"rocm deploy: nothing matches ($pattern)"} }
      for f in $matches {
        let name = ($f | path basename)
        let info = (ls -l $f | get 0)
        if $info.type == "symlink" {
          ^ln -sf ($info.target | path basename) ($destdir | path join $name)
        } else {
          cp $f ($destdir | path join $name)
        }
      }
      print $"rocm deploy: ($pattern) -> ($destdir), (($matches | length)) files"
    }
  }

  ^ccache --show-stats
}
