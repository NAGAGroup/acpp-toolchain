# build-stage-lib.nu: the cmake argument assembly behind shared/build-stage.nu
# (per-platform argument functions and `stage-args`). A library on purpose: it
# defines NO `main`, so shared/configure-smoke.nu can `source` it and configure
# with exactly the arguments the staging build uses, while build-stage.nu
# `source`s it and keeps the build itself.

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
    # ccache when present (conda-forge has none for win-arm64)
    ...(if (which ccache | is-empty) { [] } else { ["-DCMAKE_C_COMPILER_LAUNCHER=ccache" "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"] })
    "-DLLVM_TARGETS_TO_BUILD=X86;NVPTX"
    # compiler-rt and openmp are RUNTIMES on every platform (the LLVM 23 way:
    # LLVM_ENABLE_PROJECTS=openmp is a fatal error, and =compiler-rt is
    # deprecated). They are built by the bootstrapping runtimes build, a child
    # cmake driven by the just-built clang, and installed into this prefix:
    # libomp to lib/ (win: bin/ for the DLL, lib/ for the import library),
    # omp.h / omp-tools.h / ompt.h to the clang resource include dir, the
    # compiler-rt libraries under lib/clang/<major>/. The options below reach
    # the child through the runtimes PASSTHROUGH prefixes (COMPILER_RT,
    # SANITIZER, DARWIN, OPENMP, LIBOMP: llvm/runtimes/CMakeLists.txt).
    "-DLLVM_ENABLE_RUNTIMES=compiler-rt;openmp"
    # Flat lib/ for libomp and compiler-rt everywhere: AMD's tree hard-codes this OFF, upstream defaults it ON on Linux (libomp landed in lib/<triple>/ on linux-aarch64, run 38602918135).
    "-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF"
    "-DLLVM_BUILD_TOOLS=ON"
    "-DCLANG_BUILD_TOOLS=ON"
    "-DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF"
    "-DLLVM_ENABLE_RTTI=ON"
    "-DLLVM_ENABLE_EH=ON"
    "-DLLVM_EXTERNAL_PROJECTS=AdaptiveCpp"
    $"-DLLVM_EXTERNAL_ADAPTIVECPP_SOURCE_DIR=($src)/AdaptiveCpp"
    "-DLLVM_ADAPTIVECPP_LINK_INTO_TOOLS=ON"
    # conda supplies the vendor runtimes from their own packages. A relative
    # vendor root makes each vendor's app-config value $ACPP_RT_LIB_DIR-relative
    # instead of baking in the build prefix; discovery still finds each vendor
    # where the host env put it.
    "-DACPP_CUDA_ROOT=."
    "-DACPP_OCL_ROOT=."
    "-DACPP_ZE_ROOT=."
    # ACPP_HIP_ROOT=. is set only where the ROCm backend is built (linux-64
    # and win-64): see linux-x86-backend-args and windows-args.
    (if (is-windows) { "-DACPP_LIBOMP_ROOT=bin" } else { "-DACPP_LIBOMP_ROOT=lib" })
    # linux x86_64 only: the host JIT defaults to svml there (intel-cmplr-lib-rt
    # in lib/), so its app-config fallback is runtime-relative like libomp's.
    ...(if (not (is-windows)) and (not (is-darwin)) and (not (is-arm)) { ["-DACPP_SVML_ROOT=lib"] } else { [] })
    "-DWITH_CUDA_BACKEND=ON"
    "-DWITH_CPU_BACKEND=ON"
    "-DWITH_ROCM_BACKEND=OFF"
    "-DACPP_COMPILER_FEATURE_PROFILE=full"
    # The fork refuses LLVM newer than its tested range unless told otherwise;
    # this build is LLVM 23 (AMD snapshot).
    "-DACPP_EXPERIMENTAL_LLVM=ON"
    $"-DCUDAToolkit_ROOT=($prefix)"
    # The fork clones its SPIR-V translator itself (NAGAGroup/SPIRV-LLVM-
    # Translator); pin the commit: naga/amd-llvm-23, Khronos main 7d4b128d (the
    # parent of AMD's 2026-07-08 merge) + the AdaptiveCpp address-space patch.
    "-DLLVMSPIRV_COMMIT=a5fa639ff3f550780c34615830f9949bed4cba06"
    "-DOPENMP_ENABLE_LIBOMPTARGET=OFF"
    # libomp must not write into the source tree (exports/), and must not
    # install the libgomp/libiomp5 alias symlinks: libgomp.so.1 would collide
    # with the gcc runtime's libgomp in every environment.
    "-DLIBOMP_COPY_EXPORTS=OFF"
    "-DLIBOMP_INSTALL_ALIASES=OFF"
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
    # Optional LLVM / LLDB features: ON wherever the library exists on
    # conda-forge, on EVERY platform (no platform-specific trimming).
    # FORCE_ON (LLVM_ENABLE_*) / ON (LLDB_ENABLE_*) make a missing library fail
    # the configure instead of silently disabling the feature. LLDB's option
    # macro (LLDBConfig.cmake add_optional_dependency) knows only On/Off/Auto:
    # FORCE_ON there evaluates as a variable lookup and silently turns the
    # feature OFF (seen in the first smoke run). Not wanted: Lua, OCaml,
    # docs/doxygen.
    #
    # libxml2: LLVM (llvm-mt, lld-link manifest merging) and lldb.
    "-DLLVM_ENABLE_LIBXML2=FORCE_ON"
    "-DLLDB_ENABLE_LIBXML2=ON"
    # xz / liblzma: lldb (compressed debug sections, minidebuginfo).
    "-DLLDB_ENABLE_LZMA=ON"
    # python scripting. SWIG >= 4 generates the bindings; the module is built
    # against the Python LIMITED API (abi3, SWIG 4.5.1 is past the 4.2 floor and
    # the 4.4.0-only bug at LLDBConfig.cmake:247), so naga-acpp-lldb works with
    # any CPython >= 3.8 instead of the build's exact version. Limited API is
    # incompatible with LLDB_EMBED_PYTHON_HOME, which defaults to ON on Windows
    # (and would bake the BUILD prefix in anyway), so it is OFF everywhere.
    "-DLLDB_ENABLE_SWIG=ON"
    "-DLLDB_ENABLE_PYTHON=ON"
    "-DLLDB_ENABLE_PYTHON_LIMITED_API=ON"
    "-DLLDB_EMBED_PYTHON_HOME=OFF"
    # tree-sitter syntax highlighting (needs libtree-sitter AND the
    # tree-sitter CLI at build time, plus node for `tree-sitter generate`).
    # conda-forge has the CLI everywhere but win-arm64: windows-arm-args turns
    # it off there.
    "-DLLDB_ENABLE_TREESITTER=ON"
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

def is-arm [] { $nu.os-info.arch == "aarch64" }

# Windows on ARM64: OMP and OpenCL (no CUDA, Level Zero or ROCm packages exist for win-arm64). compiler-rt BUILTINS only: the vs2026 activation links clang_rt.builtins-aarch64.lib (conda-forge parity), and nothing else supplies it. No sanitizers. Otherwise the full tool set: clang-tools-extra, lldb, and LLVM as a DLL.
# Appended after windows-args, so these -D values win.
def windows-arm-args [] {
  [
    "-DLLVM_ENABLE_PROJECTS=clang;lld;lldb;clang-tools-extra"
    # LLVM as a DLL (same recipe as win-64, including CLANG_LINK_CLANG_DYLIB=OFF from windows-args, which runs first).
    "-DLLVM_BUILD_LLVM_DYLIB=ON"
    "-DLLVM_LINK_LLVM_DYLIB=ON"
    "-DLLVM_BUILD_LLVM_DYLIB_VIS=ON"
    "-DWITH_CUDA_BACKEND=OFF"
    "-DWITH_LEVEL_ZERO_BACKEND=OFF"
    "-DWITH_ROCM_BACKEND=OFF"
    # tree-sitter: libtree-sitter exists for win-arm64 but conda-forge has no
    # tree-sitter-cli for it, and lldb's FindTreeSitter requires the CLI to
    # generate the grammars (a win-64 package cannot be installed into a
    # win-arm64 environment).
    "-DLLDB_ENABLE_TREESITTER=OFF"
    "-DLLVM_TARGETS_TO_BUILD=AArch64"
    "-DLLVM_HOST_TRIPLE=aarch64-pc-windows-msvc"
    "-DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-pc-windows-msvc"
    "-DCOMPILER_RT_BUILD_BUILTINS=ON"
    "-DCOMPILER_RT_BUILD_SANITIZERS=OFF"
    "-DCOMPILER_RT_BUILD_PROFILE=OFF"
    "-DCOMPILER_RT_BUILD_LIBFUZZER=OFF"
  ]
}

# macOS: OMP and Metal, plus the full tool set: lldb (against Xcode's signed
# debugserver, no python), clang-tools-extra and compiler-rt (builtins, profile
# and the sanitizers/libFuzzer darwin supports). No bolt (no darwin port), no
# CUDA/ROCm/L0/OpenCL.
# Apple triples are inferred natively — no host/target triple
# overrides, no sysroot machinery: the activation's CMAKE_ARGS carries
# CMAKE_OSX_SYSROOT and the deployment target.
def darwin-args [src: string, prefix: string] {
  [
    "-DLLVM_ENABLE_PROJECTS=clang;lld;lldb;clang-tools-extra"
    # TheRock parity for clang hosts.
    "-DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON"
    "-DLLVM_BUILD_LLVM_DYLIB=ON"
    "-DLLVM_LINK_LLVM_DYLIB=ON"
    # lldb: Xcode's own signed debugserver (building and codesigning ours
    # needs entitlements). libedit / curses (+panel) from conda-forge, like
    # linux; python, lzma, libxml2 and tree-sitter are in common-args.
    "-DLLDB_USE_SYSTEM_DEBUGSERVER=ON"
    "-DLLVM_ENABLE_LIBEDIT=FORCE_ON"
    "-DLLDB_ENABLE_LIBEDIT=ON"
    "-DLLDB_ENABLE_CURSES=ON"
    "-DWITH_CUDA_BACKEND=OFF"
    "-DWITH_LEVEL_ZERO_BACKEND=OFF"
    "-DWITH_OPENCL_BACKEND=OFF"
    "-DWITH_ROCM_BACKEND=OFF"
    # Metal: metal-cpp is a header-only, build-only source (recipe), found
    # through METAL_INCLUDE_DIR (fork cmake/discovery/metal.cmake).
    "-DWITH_METAL_BACKEND=ON"
    $"-DMETAL_INCLUDE_DIR=($src)/metal-cpp"
    "-DLLVM_TARGETS_TO_BUILD=AArch64"
    # conda-forge's osx-arm64 CHOST. Setting this explicitly (rather than
    # letting LLVM infer its host triple) is what makes the clang cfg file
    # written by install-cfg.nu (<triple>-clang.cfg) match clang's own
    # default target, so a bare `clang` invocation finds it with no symlink.
    "-DLLVM_HOST_TRIPLE=arm64-apple-darwin20.0.0"
    "-DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-darwin20.0.0"
    # compiler-rt (a runtime, see common-args): builtins, profile, the
    # sanitizers and libFuzzer that darwin supports. XRay, MemProf and ORC
    # are linux/other-first; the embedded-Apple-platform runtimes are not
    # wanted for a macOS toolchain.
    "-DCOMPILER_RT_BUILD_BUILTINS=ON"
    "-DCOMPILER_RT_BUILD_SANITIZERS=ON"
    "-DCOMPILER_RT_BUILD_PROFILE=ON"
    "-DCOMPILER_RT_BUILD_LIBFUZZER=ON"
    "-DCOMPILER_RT_BUILD_XRAY=OFF"
    "-DCOMPILER_RT_BUILD_MEMPROF=OFF"
    "-DCOMPILER_RT_BUILD_ORC=OFF"
    "-DCOMPILER_RT_ENABLE_IOS=OFF"
    "-DCOMPILER_RT_ENABLE_WATCHOS=OFF"
    "-DCOMPILER_RT_ENABLE_TVOS=OFF"
    "-DCOMPILER_RT_ENABLE_XROS=OFF"
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
    "-DLLVM_ENABLE_PROJECTS=clang;lld;lldb;clang-tools-extra;bolt;polly"
    # compiler-rt and openmp are runtimes (common-args). The host compiler
    # here is conda gcc, which must not build the sanitizer runtimes: the
    # runtimes child is driven by the just-built clang, configured with the
    # pseudo-cross args from conda-toolchain-args below.
    # TheRock parity for GNU hosts.
    "-DLLVM_ENABLE_PEDANTIC=OFF"
    # With ccache as the compiler launcher LLVM warns about precompiled headers
    # (HandleLLVMOptions.cmake:1407); off on every platform now (win/osx above).
    "-DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON"
    # compiler-rt components that upstream supports on linux but not on
    # Windows. XRay has no Windows port at all; MemProf and ORC are
    # linux-first and not built by conda-forge's own Windows clang either.
    "-DCOMPILER_RT_BUILD_XRAY=ON"
    "-DCOMPILER_RT_BUILD_MEMPROF=ON"
    "-DCOMPILER_RT_BUILD_ORC=ON"
    # One dylib every tool links against — the seam the whole partition rests on
    "-DLLVM_BUILD_LLVM_DYLIB=ON"
    "-DLLVM_LINK_LLVM_DYLIB=ON"
    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
    # libedit / curses (+panel): lldb line editing and the `gui` command; LLVM's
    # own libedit use (LineEditor) is on too. Python, lzma, libxml2 and
    # tree-sitter are in common-args.
    "-DLLVM_ENABLE_LIBEDIT=FORCE_ON"
    "-DLLDB_ENABLE_LIBEDIT=ON"
    "-DLLDB_ENABLE_CURSES=ON"
    "-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib"
    $"-DLLVM_HOST_TRIPLE=(linux-triple)"
    $"-DLLVM_DEFAULT_TARGET_TRIPLE=(linux-triple)"
    # -pthread now folded into outer-flag-args (explicit CMAKE_*_LINKER_FLAGS
    # override *_INIT, so the old _INIT lines would have been silently dropped)
  ] ++ (if $nu.os-info.arch == "aarch64" { linux-arm-backend-args $src $prefix } else { linux-x86-backend-args $src $prefix })
    ++ (conda-toolchain-args))
}

# x86-64: the full backend set.
def linux-x86-backend-args [src: string, prefix: string] {
  [
    "-DWITH_LEVEL_ZERO_BACKEND=ON"
    "-DWITH_OPENCL_BACKEND=ON"
    # ROCm: TheRock's multi-arch tarball is a BUILD input. The fork's
    # discovery (find_package(hip CONFIG)) finds it through hip_ROOT; main()
    # adds the tree to CMAKE_FIND_ROOT_PATH so the activation's ONLY-mode
    # find_* reach it. After install, the runtime subset is copied into the
    # prefix with the tarball's layout (rocm deploy, below), and
    # ACPP_HIP_ROOT=. tells the fork the prefix IS the HIP root. The backend
    # plugins' RUNPATH is $ORIGIN/.., so the HIP libraries must sit in lib/.
    "-DWITH_ROCM_BACKEND=ON"
    "-DACPP_HIP_ROOT=."
    $"-Dhip_ROOT=($src)/rocm-dist"
    # SPIRV: TheRock's libamd_comgr.so.3 needs LLVMInitializeSPIRV{Target,TargetInfo,TargetMC,AsmPrinter} from our libLLVM (hip backend failed to load otherwise).
    "-DLLVM_TARGETS_TO_BUILD=X86;NVPTX;AMDGPU;SPIRV"
    $"-DCUDA_DEVICE_LIBS_PATH=($prefix)/nvvm/libdevice"
    $"-DOpenCL_LIBRARY=($prefix)/lib/libOpenCL.so"
    $"-DOpenCL_INCLUDE_DIR=($prefix)/include"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-HEADERS=($src)/OpenCL-Headers"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-CXX-HEADERS=($src)/OpenCL-CLHPP"
  ]
}

# aarch64: CUDA (conda-forge ships the sbsa CUDA packages for linux-aarch64)
# and OpenCL (ocl-icd). conda-forge has no Level Zero or ROCm for aarch64.
def linux-arm-backend-args [src: string, prefix: string] {
  [
    "-DWITH_CUDA_BACKEND=ON"
    "-DWITH_OPENCL_BACKEND=ON"
    "-DWITH_LEVEL_ZERO_BACKEND=OFF"
    "-DWITH_ROCM_BACKEND=OFF"
    "-DLLVM_TARGETS_TO_BUILD=AArch64;NVPTX"
    $"-DCUDA_DEVICE_LIBS_PATH=($prefix)/nvvm/libdevice"
    $"-DOpenCL_LIBRARY=($prefix)/lib/libOpenCL.so"
    $"-DOpenCL_INCLUDE_DIR=($prefix)/include"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-HEADERS=($src)/OpenCL-Headers"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-CXX-HEADERS=($src)/OpenCL-CLHPP"
  ]
}

def windows-args [src: string, libprefix: string, build: string] {
  [
    # compiler-rt and openmp are runtimes (common-args), built by the
    # bootstrapping runtimes build with the just-built clang-cl. bolt/polly
    # stay linux-only; clang-tools-extra and lldb are added for the full tool
    # set.
    "-DLLVM_ENABLE_PROJECTS=clang;lld;lldb;clang-tools-extra"
    # TheRock parity for clang hosts.
    "-DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON"
    # libomp.dll / libomp.lib (not the MSVC-scheme libomp140.x86_64.dll).
    "-DOPENMP_MSVC_NAME_SCHEME=OFF"
    # LLVM as a DLL on Windows (upstream's documented recipe: LLVM Discourse,
    # "LLVM is buildable as a Windows DLL"): tools link LLVM-<ver>.dll, so the
    # partition matches linux's libLLVM.so shape. clang-cpp.dll is still built
    # (clang/tools/CMakeLists.txt adds clang-shlib when MSVC AND
    # LLVM_BUILD_LLVM_DYLIB_VIS), but tools must NOT link it:
    # CLANG_LINK_CLANG_DYLIB defaults to LLVM_LINK_LLVM_DYLIB
    # (clang/CMakeLists.txt), and clang's headers carry almost no CLANG_ABI
    # export annotations, so clang-offload-wrapper.exe failed to link
    # (getClangToolFullVersion undefined, run 38583556687). Hence the explicit OFF.
    "-DLLVM_BUILD_LLVM_DYLIB=ON"
    "-DLLVM_LINK_LLVM_DYLIB=ON"
    "-DLLVM_BUILD_LLVM_DYLIB_VIS=ON"
    "-DCLANG_LINK_CLANG_DYLIB=OFF"
    # lldb python / lzma / libxml2 / tree-sitter are in common-args (swig,
    # python, xz, libxml2 and the tree-sitter CLI all exist for win-64). Left OFF
    # because no usable library exists for Windows on conda-forge:
    #  - libedit: no windows build (a unix line-editing library).
    #  - curses: ncurses has no windows build; pdcurses (win-64 only) ships no
    #    panel library and no terminfo symbols, which lldb's FindCursesAndPanel
    #    requires, and win-arm64 has no curses package at all.
    "-DLLDB_ENABLE_LIBEDIT=OFF"
    "-DLLDB_ENABLE_CURSES=OFF"
    # The host python for FindPython3 (the build env carries one as well).
    $"-DPython3_ROOT_DIR=($libprefix | path dirname)"
    # See linux-args: XRay has no Windows port, and MemProf/ORC are linux-first.
    # ASan, the profile runtime and libFuzzer DO support Windows and are
    # enabled in common-args.
    "-DCOMPILER_RT_BUILD_XRAY=OFF"
    "-DCOMPILER_RT_BUILD_MEMPROF=OFF"
    "-DCOMPILER_RT_BUILD_ORC=OFF"
    # Level Zero and OpenCL loaders BOTH ship for win-64 (level-zero-devel,
    # khronos-opencl-icd-loader), so the Intel backends are built here too.
    # Upstream's CI disables OpenCL on Windows but the docs never say it
    # cannot work; if this proves wrong, CI is where we find out.
    "-DWITH_LEVEL_ZERO_BACKEND=ON"
    "-DWITH_OPENCL_BACKEND=ON"
    # ROCm on Windows x64 from TheRock's windows multiarch tarball (a
    # win-64-only source in the recipe; win-arm64 overrides this OFF).
    ...(if (($src | path join "rocm-dist") | path exists) { [
      "-DWITH_ROCM_BACKEND=ON"
      "-DACPP_HIP_ROOT=."
      $"-Dhip_ROOT=($src)/rocm-dist"
    ] } else { [] })
    $"-DOpenCL_LIBRARY=($libprefix)/lib/OpenCL.lib"
    $"-DOpenCL_INCLUDE_DIR=($libprefix)/include"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-HEADERS=($src)/OpenCL-Headers"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-CXX-HEADERS=($src)/OpenCL-CLHPP"
    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
    "-DLLVM_TOOL_BUGPOINT_BUILD=OFF"
    "-DLLVM_HOST_TRIPLE=x86_64-pc-windows-msvc"
    "-DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-pc-windows-msvc"
    # The fork honours upstream's CUDA_DEVICE_LIBS_PATH for libdevice.
    $"-DCUDA_DEVICE_LIBS_PATH=($libprefix)/nvvm/libdevice"
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
    "-DLLVM_TARGETS_TO_BUILD=X86;NVPTX;AMDGPU"
  ]
}

# The complete cmake argument list for this platform's LLVM+AdaptiveCpp
# configure. main() runs it, and shared/configure-smoke.nu calls the very same
# function, so the free gate configures exactly what CI configures. It reads
# the conda flags from the environment (CFLAGS, CXXFLAGS, LDFLAGS, CMAKE_ARGS),
# so it must run BEFORE main() strips them.
def stage-args [src: string, prefix: string, build: string] {
  let flag_args = (outer-flag-args)

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

  # The ROCm tree is a work-dir input outside the activation's find roots
  # (CMAKE_FIND_ROOT_PATH = prefix + sysroot, find_library/find_path ONLY), so
  # add it as a root. Paths already under a root are not re-rooted, so
  # hip_ROOT resolves as given.
  let rocm = ($src | path join "rocm-dist")
  let activation_args = (if ($rocm | path exists) {
    $activation_args | each {|a|
      if ($a | str starts-with "-DCMAKE_FIND_ROOT_PATH=") { $"($a);($rocm)" } else { $a }
    }
  } else { $activation_args })

  ($activation_args
    | append (common-args $src $prefix $build)
    | append $flag_args
    | append (if (is-windows) {
        (windows-args $src $prefix $build) ++ (if (is-arm) { windows-arm-args } else { [] })
      } else if (is-darwin) {
        (darwin-args $src $prefix)
      } else {
        (linux-args $src $prefix)
      }))
}

