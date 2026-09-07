# build-stage.nu — the ONE LLVM+AdaptiveCpp build behind every shipped package.
#
# ============================================================================
# PROVENANCE. This script is the merge of the BUILD half of six conda-forge
# feedstocks, as vendored verbatim in the reference monolith
# (NAGAGroup/llvm-feedstocks-monolith@cb9f3be, `recipe/<feedstock>/`), plus
# AdaptiveCpp. Every non-obvious flag below carries the feedstock script it
# came from, so the next person can diff rather than re-derive:
#
#   llvmdev/build.sh, llvmdev/bld.bat          the LLVM core configure
#   clangdev/build.sh, clangdev/build.bat      clang flags + the install fixups
#   compiler-rt/build.sh                       the darwin compiler-rt flags
#   lld/build.sh                               LLVM_ENABLE_LIBCXX on osx
#   lldb/build.sh, lldb/bld.bat                the LLDB_* flags
#   openmp/build.sh, openmp/install_pkg.sh     the openmp seds + install cleanup
#   libcxx/build.sh                            the LIBCXX_* runtime flags
#
# WHY THIS IS ONE NUSHELL SCRIPT AND NOT THE LIFTED .sh/.bat PAIR. Upstream has
# one script per feedstock per platform — twelve files for what is, for us, a
# single cmake configure. Merging them means rewriting them regardless; doing
# that into bash+batch would mean maintaining the merge twice, in two languages,
# with the acpp logic (the runtimes pseudo-cross, the ROCm deploy, the ccache
# wiring) rewritten out of a form that is already proven green. The FLAGS are
# lifted verbatim; the shell is ours.
#
# ⚠ NUSHELL LANDMINES, each paid for once:
#   * `cp -P` preserves symlinks. `cp -p` is --progress and DEREFERENCES them —
#     an LLVM tree is a symlink farm and that inflates it by ~1 GB without ever
#     failing a build.
#   * backslash is a glob ESCAPE. Normalise Windows paths to forward slashes on
#     BOTH sides of every comparison and before every `glob`.
#   * any `(word ...)` inside a `$"..."` string is CODE, not text. A parse check
#     does not catch a wrong one; it silently evaluates.
# ============================================================================

def is-windows [] { $nu.os-info.name == "windows" }
def is-darwin [] { $nu.os-info.name == "macos" }

def cpu-count [] { $env.CPU_COUNT? | default (sys cpu | length | into string) | into int }

# Link jobs are memory-bound, not CPU-bound: LLVM links are ~1-2 GB each.
def link-jobs [] {
  let mem_gb = (((sys mem | get total | into int) / 1073741824) | math round)
  [1 ([($mem_gb // 4) (cpu-count)] | math min)] | math max
}

def fwd [p: string] { $p | str replace --all '\' '/' }

# The conda toolchain triple. `CONDA_TOOLCHAIN_HOST` is exported by the
# compiler activation package and is what upstream llvmdev passes to
# LLVM_HOST_TRIPLE / LLVM_DEFAULT_TARGET_TRIPLE. The fallbacks are the same
# values the reference monolith derives per platform, used only if no
# activation ran.
def conda-host-triple [] {
  let a = ($env.CONDA_TOOLCHAIN_HOST? | default "")
  if $a != "" { return $a }
  if (is-windows) { "x86_64-pc-windows-msvc"
  } else if (is-darwin) { "arm64-apple-darwin20.0.0"
  } else if $nu.os-info.arch == "aarch64" { "aarch64-conda-linux-gnu"
  } else { "x86_64-conda-linux-gnu" }
}

# clangdev's TARGET / TARGET_NO_VER. Upstream carries them as an eight-row
# variant key; the reference monolith derives them per platform because a
# variant FILE cannot pick the row matching the platform being rendered.
# TARGET_NO_VER differs only on osx, where dropping the darwin version is what
# lets `-arch x86_64 -arch arm64` work (conda-forge.github.io issue 2695).
def target-triple [] { conda-host-triple }
def target-triple-no-ver [] {
  if (is-darwin) { "arm64-apple-darwin" } else { conda-host-triple }
}

# ============================================================================
# THE CONFIGURE
# ============================================================================

# Flags common to all three platforms: upstream llvmdev's core set, plus the
# AdaptiveCpp injection and the acpp backend switches.
def common-args [src: string, prefix: string, deps: string, build: string] {
  let llvm_major = $env.ACPP_LLVM_MAJOR
  [
    # ---- llvmdev/build.sh + llvmdev/bld.bat, verbatim -----------------------
    "-DCMAKE_BUILD_TYPE=Release"
    $"-DCMAKE_INSTALL_PREFIX=($prefix)"
    # "Sometimes projects install into lib64... on conda-forge we keep
    # libraries in plain lib" — conda-forge's documented flag, and LLVM is
    # exactly such a project.
    "-DCMAKE_INSTALL_LIBDIR=lib"
    "-DLLVM_ENABLE_DUMP=ON"
    "-DLLVM_ENABLE_LIBXML2=FORCE_ON"
    "-DLLVM_ENABLE_RTTI=ON"
    "-DLLVM_ENABLE_ZLIB=FORCE_ON"
    "-DLLVM_ENABLE_ZSTD=FORCE_ON"
    "-DLLVM_INCLUDE_BENCHMARKS=OFF"
    "-DLLVM_INCLUDE_DOCS=OFF"
    "-DLLVM_INCLUDE_EXAMPLES=OFF"
    # UPSTREAM SAYS ON, AND IT IS LOAD-BEARING FOR THE SHIPPED SET: with
    # INCLUDE_TESTS/INSTALL_UTILS off there is no libexec/llvm/{not,FileCheck},
    # which llvmdev's own package test asserts and which llvm-tools ships. The
    # pre-rebuild tree had these OFF and therefore could not have satisfied the
    # superset rule.
    "-DLLVM_INCLUDE_TESTS=ON"
    "-DLLVM_INCLUDE_UTILS=ON"
    "-DLLVM_INSTALL_UTILS=ON"
    "-DLLVM_UTILS_INSTALL_DIR=libexec/llvm"
    "-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=WebAssembly"

    # ---- clangdev/build.sh + clangdev/build.bat, verbatim -------------------
    "-DCLANG_FORCE_MATCHING_LIBCLANG_SOVERSION=OFF"
    "-DCLANG_INCLUDE_TESTS=OFF"
    "-DCLANG_INCLUDE_DOCS=OFF"
    "-DCLANG_DEFAULT_PIE_ON_LINUX=ON"

    # ---- lldb/build.sh + lldb/bld.bat --------------------------------------
    # Upstream builds lldb with python, libedit, curses, lzma and libxml2 all
    # ON, and its host list carries the packages for them. The pre-rebuild tree
    # switched four of the five OFF; that is a smaller lldb than a conda-forge
    # user would get, and the superset rule says we do not do that.
    "-DLLDB_ENABLE_PYTHON=ON"
    "-DLLDB_ENABLE_PYTHON_LIMITED_API=OFF"
    "-DLLDB_ENABLE_TESTS=OFF"

    # ---- ours: AdaptiveCpp ---------------------------------------------------
    # THE STRUCTURAL CONSTRAINT. acpp component mode injects here, into the
    # llvm-tree configure; LLVM_EXTERNAL_PROJECTS is an llvm-tree option and
    # add_clang_library/add_llvm_pass_plugin are in-tree macros, so
    # conda-forge's llvmdev -> clangdev split cannot carry acpp. The compiler
    # core is unavoidably ONE build.
    "-DLLVM_EXTERNAL_PROJECTS=AdaptiveCpp"
    $"-DLLVM_EXTERNAL_ADAPTIVECPP_SOURCE_DIR=($src)/AdaptiveCpp"
    "-DLLVM_ADAPTIVECPP_LINK_INTO_TOOLS=ON"
    "-DACPP_COMPILER_FEATURE_PROFILE=full"
    "-DWITH_CPU_BACKEND=ON"
    "-DWITH_ACCELERATED_CPU=ON"
    "-DWITH_CUDA_BACKEND=ON"
    "-DWITH_ROCM_BACKEND=OFF"
    "-DLLVM_ENABLE_EH=ON"
    "-DLLVM_BUILD_TOOLS=ON"
    "-DCLANG_BUILD_TOOLS=ON"
    "-DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF"
    # DEPENDENCY ROOT, not the install prefix: the CUDA toolkit arrives as a
    # HOST dependency and lives at the TOP of the prefix, while this build
    # installs into <prefix>/_stage. Passing the stage here would search a
    # directory we are still creating.
    $"-DCUDAToolkit_ROOT=($deps)"
    $"-DCUDA_TOOLKIT_ROOT_DIR=($deps)"
    # The SPIRV-LLVM-Translator comes from acpp-llvm-spirv and lands at
    # bin/llvm-spirv in the same prefix, so this build neither fetches nor
    # builds it. "." rather than "" keeps the baked
    # HIPSYCL_RELATIVE_LLVMSPIRV_PATH relative — an empty value leaves a
    # leading slash and makes it absolute.
    "-DACPP_EXTERNAL_LLVMSPIRV=ON"
    "-DLLVMSPIRV_RELATIVE_INSTALLDIR=."
    "-DOPENMP_ENABLE_LIBOMPTARGET=OFF"
    # compiler-rt: builtins plus the sanitizer runtimes. All OFF would make the
    # toolchain a NON-drop-in replacement — `clang -fsanitize=address` would
    # fail to link against a runtime we never built. Per-component rather than
    # a blanket ON because the components have genuinely different platform
    # support; the per-platform sets below add the ones that are linux-only.
    "-DCOMPILER_RT_BUILD_BUILTINS=ON"
    "-DCOMPILER_RT_BUILD_SANITIZERS=ON"
    "-DCOMPILER_RT_BUILD_PROFILE=ON"
    "-DCOMPILER_RT_BUILD_LIBFUZZER=ON"
    "-DCMAKE_C_COMPILER_LAUNCHER=ccache"
    "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
    $"-DLLVM_PARALLEL_LINK_JOBS=(link-jobs)"
  ]
}

# ---------------------------------------------------------------------------
# LINUX
# ---------------------------------------------------------------------------
def linux-args [src: string, prefix: string, deps: string] {
  ([
    # bolt is linux-only (ELF-only, no darwin port). polly is OUT of round 1:
    # conda-forge's polly-feedstock has not been touched in almost three years
    # and has no llvm-21 build at all.
    "-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra;lld;lldb;openmp;bolt"
    # compiler-rt goes through the RUNTIMES bootstrap on linux ONLY: the host
    # compiler here is conda gcc, which must not build the sanitizer runtimes.
    # On win and osx the host compiler is already clang, so compiler-rt rides
    # LLVM_ENABLE_PROJECTS there and the bootstrap child buys nothing.
    "-DLLVM_ENABLE_RUNTIMES=compiler-rt"
    # compiler-rt components upstream supports on linux but not on Windows.
    # XRay has no Windows port at all; MemProf and ORC are linux-first and are
    # not built by conda-forge's own Windows clang either.
    "-DCOMPILER_RT_BUILD_XRAY=ON"
    "-DCOMPILER_RT_BUILD_MEMPROF=ON"
    "-DCOMPILER_RT_BUILD_ORC=ON"
    # llvmdev/build.sh: linux-64 only.
    "-DLLVM_USE_INTEL_JITEVENTS=ON"
    # One dylib every tool links against — the seam the whole package
    # partition rests on. llvmdev/build.sh sets both.
    "-DLLVM_BUILD_LLVM_DYLIB=ON"
    "-DLLVM_LINK_LLVM_DYLIB=ON"
    "-DLLVM_DYLIB_SYMBOL_VERSIONING=ON"
    # llvmdev/build.sh
    "-DLLVM_ENABLE_BACKTRACES=ON"
    "-DLLVM_ENABLE_TERMINFO=OFF"
    $"-DCMAKE_LIBRARY_PATH=($deps)"
    # lldb/build.sh has these ON and its host list carries ncurses, libedit,
    # liblzma-devel and libxml2-devel to match.
    "-DLLDB_ENABLE_LIBEDIT=ON"
    "-DLLDB_ENABLE_CURSES=ON"
    "-DLLDB_ENABLE_LZMA=ON"
    "-DLLDB_ENABLE_LIBXML2=ON"
    "-DLLDB_USE_SYSTEM_DEBUGSERVER=OFF"
    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
    "-DCMAKE_INSTALL_RPATH=$ORIGIN/../lib"
    $"-DLLVM_HOST_TRIPLE=(conda-host-triple)"
    $"-DLLVM_DEFAULT_TARGET_TRIPLE=(conda-host-triple)"
  ] ++ (if $nu.os-info.arch == "aarch64" { linux-arm-backend-args } else { linux-x86-backend-args $src $deps })
    ++ (conda-toolchain-args))
}

# x86-64: the full backend set.
# `deps` is the DEPENDENCY ROOT (top of the prefix, where host deps land),
# never the stage install dir — CUDA's libdevice and the OpenCL loader are host
# packages.
def linux-x86-backend-args [src: string, deps: string] {
  [
    "-DWITH_LEVEL_ZERO_BACKEND=ON"
    "-DWITH_OPENCL_BACKEND=ON"
    # ROCm: the TheRock core tarball is a BUILD input — ROCM_PATH points into
    # the extracted source tree so acpp's find_* succeed; the runtime subset is
    # deployed into the prefix post-install and carved into acpp-runtime-rocm.
    # Overrides the common-args OFF (cmake: last -D wins) and widens the LLVM
    # target list — llvm-to-amdgpu JITs through libLLVM's AMDGPU backend.
    "-DWITH_ROCM_BACKEND=ON"
    $"-DROCM_PATH=($src)/rocm-dist"
    # PRESET, not searched: the activation's CMAKE_ARGS confines find_library
    # and find_path to the prefix + sysroot (FIND_ROOT_PATH_MODE_*=ONLY), and
    # the ROCm tree is a work-dir input outside both roots, so its HINTS are
    # discarded. A preset cache variable skips the search entirely. hsakmt is
    # deliberately NOT preset — TheRock ships it static-only (folded into
    # hsa-runtime), so it must stay NOTFOUND and the deploy skips it.
    $"-DAMDHIP64_LIBRARY=($src)/rocm-dist/lib/libamdhip64.so"
    $"-DHSARUNTIME64_LIBRARY=($src)/rocm-dist/lib/libhsa-runtime64.so"
    $"-DAMDCOMGR_LIBRARY=($src)/rocm-dist/lib/libamd_comgr.so"
    $"-DROCPROFILERREGISTER_LIBRARY=($src)/rocm-dist/lib/librocprofiler-register.so"
    $"-DHIPRTC_LIBRARY=($src)/rocm-dist/lib/libhiprtc.so"
    $"-DROCM_DEVICE_LIBS_PATH=($src)/rocm-dist/lib/llvm/amdgcn/bitcode"
    "-DLLVM_TARGETS_TO_BUILD=X86;NVPTX;AMDGPU"
    $"-DCUDA_DEVICE_LIBS_PATH=($deps)/nvvm/libdevice"
    $"-DOpenCL_LIBRARY=($deps)/lib/libOpenCL.so"
    $"-DOpenCL_INCLUDE_DIR=($deps)/include"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-HEADERS=($src)/OpenCL-Headers"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-CXX-HEADERS=($src)/OpenCL-CLHPP"
  ]
}

# aarch64: OMP-ONLY by design. Not a round-1 platform; kept because the arg set
# is the only statement of what an arm build would enable.
def linux-arm-backend-args [] {
  [
    "-DWITH_CUDA_BACKEND=OFF"
    "-DWITH_LEVEL_ZERO_BACKEND=OFF"
    "-DWITH_OPENCL_BACKEND=OFF"
    "-DWITH_ROCM_BACKEND=OFF"
    "-DLLVM_TARGETS_TO_BUILD=AArch64"
  ]
}

# Where the conda toolchain lives, for the compiler-rt runtimes sub-build.
# Returns [] when neither can be located, so the build fails with the real
# compiler error rather than a confusing empty --sysroot=.
def conda-toolchain-args [] {
  let sysroot = ($env.CONDA_BUILD_SYSROOT? | default "")
  let bp = ($env.BUILD_PREFIX? | default "")
  # conda's own layout when CONDA_BUILD_SYSROOT is not exported.
  let derived = (if $bp != "" { [$bp (conda-host-triple) "sysroot"] | path join } else { "" })
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

  # PSEUDO-CROSS, done the way LLVM's own machinery expects (verified against
  # llvm/runtimes/CMakeLists.txt + LLVMExternalProjectUtils.cmake):
  #
  #   * The runtimes are configured by a SEPARATE child cmake driven by the
  #     just-built clang. That child receives compilers, LLVM paths and
  #     LLVM_HOST_TRIPLE from the outer build — but NEVER the outer
  #     CMAKE_{C,CXX}_FLAGS. Its flags are seeded from the ENVIRONMENT
  #     (CFLAGS/CXXFLAGS), which carry conda's gcc-shaped flags. main()
  #     therefore STRIPS those from the env and passes them to the OUTER
  #     configure explicitly — outer build unchanged, child build clean.
  #   * Everything the child needs beyond that goes through RUNTIMES_CMAKE_ARGS
  #     verbatim: --sysroot finds the C library headers (glibc 2.28, our
  #     redistributability floor); --gcc-toolchain finds the C++ stdlib
  #     headers; COMPILER_TARGET is clang's --target and must match the sysroot
  #     triple, which is what makes the pseudo-cross EXPLICIT rather than
  #     accidental.
  #   * CMAKE_FIND_ROOT_PATH* mirrors the compiler activation package's own
  #     CMAKE_ARGS, which the child cannot inherit. The embedded list separator
  #     is `|`: the child ExternalProject declares LIST_SEPARATOR | and LLVM's
  #     own forwarding rewrites `;` to `|` for exactly this case.
  #   * Deliberately NOT set: CMAKE_SYSTEM_NAME=Linux — it flips the child into
  #     full cross mode and changes find semantics wholesale, which the
  #     explicit FIND_ROOT settings above make unnecessary.
  let triple = (conda-host-triple)
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

# ---------------------------------------------------------------------------
# WINDOWS
# `libprefix` is the DEPENDENCY ROOT (%PREFIX%\Library), never the stage
# install dir: every path it feeds (OpenCL, the CUDA toolkit, nvcc) belongs to
# a host package sitting at the top of the prefix.
# ---------------------------------------------------------------------------
def windows-args [src: string, libprefix: string, build: string] {
  [
    # compiler-rt rides LLVM_ENABLE_PROJECTS on win — NOT the runtimes
    # bootstrap. The bootstrap's purpose (keep a wrong-family host compiler
    # from building the sanitizer runtimes) is vacuous here: the host compiler
    # IS clang-cl, pinned in the recipe to the exact LLVM version being built.
    # The runtimes child never configured on win (runs 31350122413 /
    # 31351719706), and upstream AdaptiveCpp's own windows-acppllvm.yml uses
    # the projects path too.
    "-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra;lld;lldb;openmp;compiler-rt"
    # FLIPPED ON for this rebuild (it was OFF): shared libLLVM means far
    # fewer and faster links on the slowest leg. This is a BUILD SPEED
    # decision, not a plugin-support one.
    "-DLLVM_BUILD_LLVM_DYLIB=ON"
    "-DLLVM_LINK_LLVM_DYLIB=ON"
    # llvmdev/bld.bat: the C dylib is a win-only upstream output
    # (libllvm-c<major>), which the ratified subset ships on win-64.
    "-DLLVM_BUILD_LLVM_C_DYLIB=ON"
    # llvmdev/bld.bat, verbatim
    "-DLLVM_USE_INTEL_JITEVENTS=ON"
    "-DLLVM_USE_SYMLINKS=OFF"
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL"
    "-DCMAKE_POLICY_DEFAULT_CMP0111=NEW"
    $"-DCMAKE_PREFIX_PATH=($libprefix)"
    # See linux-args: XRay has no Windows port, and MemProf/ORC are not built
    # for Windows by conda-forge's clang either. ASan, the profile runtime and
    # libFuzzer DO support Windows and are enabled in common-args.
    "-DCOMPILER_RT_BUILD_XRAY=OFF"
    "-DCOMPILER_RT_BUILD_MEMPROF=OFF"
    "-DCOMPILER_RT_BUILD_ORC=OFF"
    # lldb/bld.bat: swig-generated bindings against the host interpreter, and
    # the site-packages layout conda uses on win.
    "-DLLDB_ENABLE_SWIG=ON"
    "-DLLDB_EMBED_PYTHON_HOME=OFF"
    # UPSTREAM WRITES `..\Lib\site-packages` — relative to CMAKE_INSTALL_PREFIX,
    # which for upstream is %LIBRARY_PREFIX%, so `..` reaches %PREFIX% and the
    # bindings land where a conda python looks for them. OUR install prefix is
    # <layout_root>/_stage, so the same value would put them at
    # <layout_root>/Lib/site-packages — OUTSIDE THE STAGE, where no slicer can
    # reach them and where they would instead become content of _acpp-stage
    # itself, at a path nothing consumes. The `..` is dropped so they land
    # INSIDE the stage; acpp-lldb's install script is what carries them the rest
    # of the way, to %PREFIX%\Lib\site-packages.
    #
    # This is the one place the stage cannot mirror the final layout by relative
    # depth, because site-packages sits ABOVE the layout root on win. Safe here
    # and only here: the module it contains is a .pyd, and Windows resolves its
    # DLLs through the search path rather than through a stored relative rpath.
    '-DLLDB_PYTHON_RELATIVE_PATH=Lib/site-packages'
    "-DLLDB_ENABLE_LIBEDIT=OFF"
    "-DLLDB_ENABLE_CURSES=OFF"
    # Level Zero and OpenCL loaders BOTH ship for win-64 (level-zero-devel,
    # khronos-opencl-icd-loader), so the Intel backends are built here too.
    "-DWITH_LEVEL_ZERO_BACKEND=ON"
    "-DWITH_OPENCL_BACKEND=ON"
    $"-DOpenCL_LIBRARY=($libprefix)/lib/OpenCL.lib"
    $"-DOpenCL_INCLUDE_DIR=($libprefix)/include"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-HEADERS=($src)/OpenCL-Headers"
    $"-DFETCHCONTENT_SOURCE_DIR_OCL-CXX-HEADERS=($src)/OpenCL-CLHPP"
    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON"
    "-DLLVM_TOOL_BUGPOINT_BUILD=OFF"
    "-DLLVM_TARGETS_TO_BUILD=X86;NVPTX"
    "-DLLVM_HOST_TRIPLE=x86_64-pc-windows-msvc"
    "-DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-pc-windows-msvc"
    # AdaptiveCpp still uses the DEPRECATED FindCUDA module
    # (`find_package(CUDA QUIET)`), which on Windows searches a <root>/lib/x64
    # toolkit layout. conda ships the import libs flat in Library/lib, so
    # detection silently fails and acpp aborts with "CUDA was not found". Seed
    # the cache entries with the real paths so the find_* calls short-circuit.
    $"-DCUDA_TOOLKIT_ROOT_DIR=($libprefix)"
    $"-DCUDA_NVCC_EXECUTABLE=($libprefix)/bin/nvcc.exe"
    $"-DCUDA_TOOLKIT_INCLUDE=($libprefix)/include"
    $"-DCUDA_CUDART_LIBRARY=($libprefix)/lib/cudart.lib"
    $"-DCUDA_DEVICE_LIBS_PATH=($libprefix)/nvvm/libdevice"
    # AdaptiveCpp probes the BUILD compiler for -mcpu=native / -march=native
    # and uses the result as a proxy for whether llc supports -mcpu=native at
    # JIT time — upstream's own comment concedes this is the wrong check ("We
    # should actually check llc/opt here!"). MSVC rejects those spellings, so
    # the probe fails even though the llc we ship handles -mcpu=native fine.
    # Force exactly the value the passing path yields on linux.
    "-DACPP_HOST_FORCE_MCPU_TARGET=native"
    # AdaptiveCpp requires a clang-family driver (GCC/Clang builtin atomics
    # MSVC lacks). Upstream llvmdev's bld.bat sets CC=CXX=cl.exe; we cannot.
    # The plain `clang` package supplies clang-cl and the vs2026 activation
    # supplies the MSVC headers/libs/SDK it targets.
    "-DCMAKE_C_COMPILER=clang-cl"
    "-DCMAKE_CXX_COMPILER=clang-cl"
    # OpenCL-CLHPP defaults BUILD_EXAMPLES and BUILD_DOCS to ON. Pulled in via
    # FetchContent, its examples inherit LLVM's exceptions-disabled flags and
    # fail under clang-cl ("cannot use 'throw' with exceptions disabled").
    "-DBUILD_EXAMPLES=OFF"
    "-DBUILD_DOCS=OFF"
  ]
}

# ---------------------------------------------------------------------------
# macOS. Apple triples are inferred natively — no host/target triple overrides
# and no sysroot machinery: the activation's CMAKE_ARGS carries
# CMAKE_OSX_SYSROOT and the deployment target.
# ---------------------------------------------------------------------------
def darwin-args [src: string, prefix: string] {
  [
    "-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra;lld;lldb;openmp;compiler-rt"
    # libcxx and libcxxabi are RUNTIMES, never projects (LLVM refuses the
    # projects spelling since 16). osx-arm64 ONLY: that IS the native platform
    # C++ library there and we build everything we ship, while on linux and win
    # acpp's runtime uses libstdc++/the MSVC stdlib and anyone wanting libc++
    # is not building an acpp application.
    "-DLLVM_ENABLE_RUNTIMES=libcxx;libcxxabi"
    # libcxx/build.sh, verbatim
    "-DLIBCXX_ENABLE_TIME_ZONE_DATABASE=ON"
    "-DLIBCXX_INCLUDE_BENCHMARKS=OFF"
    "-DLIBCXX_INCLUDE_DOCS=OFF"
    "-DLIBCXX_INCLUDE_TESTS=OFF"
    # upstream's `hardening` variant has rows none/debug; the debug row carries
    # a run_export forcing `libcxx =*=debug*` so it cannot reach production. We
    # build the production row only.
    "-DLIBCXX_HARDENING_MODE=none"
    "-DLIBCXX_ENABLE_VENDOR_AVAILABILITY_ANNOTATIONS=ON"
    "-DLIBCXXABI_USE_LLVM_UNWINDER=OFF"
    "-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF"
    # clangdev/build.sh + lld/build.sh, osx branch
    "-DLLVM_ENABLE_LIBCXX=ON"
    "-DLLVM_VERSIONED_DYLIB_NAME_ON_DARWIN=ON"
    "-DLLVM_UNVERSIONED_LIBCLANG_ON_DARWIN=OFF"
    # llvmdev/build.sh, osx branch
    "-DLLVM_UNVERSIONED_LIBLTO_ON_DARWIN=OFF"
    # compiler-rt/build.sh, osx branch. Single-arch: we ship osx-arm64 only.
    "-DDARWIN_osx_ARCHS=arm64"
    "-DCOMPILER_RT_ENABLE_IOS=Off"
    # lldb/build.sh, osx branch
    "-DLLDB_USE_SYSTEM_DEBUGSERVER=ON"
    "-DLLDB_ENABLE_LIBEDIT=ON"
    "-DLLDB_ENABLE_CURSES=ON"
    "-DLLDB_ENABLE_LZMA=ON"
    "-DLLDB_ENABLE_LIBXML2=ON"
    # conda-forge's documented flags: "Prevent CMake from using system-wide
    # macOS packages."
    "-DCMAKE_FIND_FRAMEWORK=NEVER"
    "-DCMAKE_FIND_APPBUNDLE=NEVER"
    "-DLLVM_BUILD_LLVM_DYLIB=ON"
    "-DLLVM_LINK_LLVM_DYLIB=ON"
    "-DLLVM_TARGETS_TO_BUILD=AArch64"
    # No GPU backends on mac in round 1 (Metal is its own pass). Overrides
    # common-args' CUDA=ON — cmake takes the last -D.
    "-DWITH_CUDA_BACKEND=OFF"
    "-DWITH_LEVEL_ZERO_BACKEND=OFF"
    "-DWITH_OPENCL_BACKEND=OFF"
    "-DWITH_ROCM_BACKEND=OFF"
    "-DCMAKE_INSTALL_RPATH=@loader_path/../lib"
  ]
}

# LINUX/OSX ONLY: the outer configure must receive the conda flags EXPLICITLY
# once main() strips them from the env (see conda-toolchain-args). Replicates
# cmake's own env-seeding semantics: CFLAGS->CMAKE_C_FLAGS,
# CXXFLAGS->CMAKE_CXX_FLAGS, LDFLAGS->all three *_LINKER_FLAGS.
#
# On WINDOWS this returns NOTHING, deliberately. An explicit -DCMAKE_CXX_FLAGS
# on the command line pre-seeds the cache and suppresses CMake's Windows-MSVC
# platform defaults (/DWIN32 /D_WINDOWS /EHsc) — and those defaults are
# LOAD-BEARING: AdaptiveCpp guards its POSIX includes with `#ifndef WIN32`
# (plain WIN32, NOT the compiler builtin _WIN32; the macro only exists because
# CMake's default flags define it), so clobbering them broke omp_queue.cpp with
# "'unistd.h' file not found" (run 31350122413).
def outer-flag-args [] {
  if (is-windows) { return [] }
  let cflags = ($env.CFLAGS? | default "")
  # conda-forge's documented fix for libc++ availability errors when targeting
  # an older macOS than a symbol was introduced in: clang assumes the SYSTEM
  # libc++, while conda-forge ships its own modern one. Cheap insurance at
  # deployment target 11.0, and the KB's own remedy.
  let cxxflags = (if (is-darwin) {
    ([($env.CXXFLAGS? | default "") "-D_LIBCPP_DISABLE_AVAILABILITY"] | str join " " | str trim)
  } else {
    ($env.CXXFLAGS? | default "")
  })
  let base_ld = ($env.LDFLAGS? | default "")
  let ldflags = (if (is-darwin) { $base_ld } else { ([$base_ld "-pthread"] | str join " " | str trim) })
  [
    $"-DCMAKE_C_FLAGS=($cflags)"
    $"-DCMAKE_CXX_FLAGS=($cxxflags)"
    $"-DCMAKE_EXE_LINKER_FLAGS=($ldflags)"
    $"-DCMAKE_SHARED_LINKER_FLAGS=($ldflags)"
    $"-DCMAKE_MODULE_LINKER_FLAGS=($ldflags)"
  ]
}

# ============================================================================
# GUARDS AND FIXUPS
# ============================================================================

# Dump the runtimes/builtins child-configure failure evidence into the CI log.
# The console only ever shows "ABI info - failed"; the WHY lives in the
# children's configure logs, which no runner surfaces on its own.
# CMake >= 3.26 does NOT write CMakeError.log anymore — try_compile evidence
# lives in CMakeFiles/CMakeConfigureLog.yaml.
def dump-runtimes-logs [build: string] {
  let root = (fwd ($build | path join "runtimes"))
  for f in (glob $"($root)/**/CMakeConfigureLog.yaml") {
    print $"===== child configure evidence: ($f) ====="
    let text = (open --raw $f | lines)
    $text | first 500 | str join "\n" | print
    print $"===== ... tail of ($f) ====="
    $text | last 200 | str join "\n" | print
  }
}

# LICENCE-DRIFT GUARD. The shipped packages carve files out of this build and
# have no source tree of their own, so their `license_file` points at the
# vendored texts under _shared/licenses/. This is the only place that can still
# see both the vendored copy and the real licence in the extracted source. A
# pin bump that changes a licence fails HERE, loudly, instead of shipping stale
# text.
def check-licences [src: string] {
  for pair in ([
    [($src | path join "vendored-licenses" "llvm-LICENSE.TXT"), ($src | path join "llvm-project" "LICENSE.TXT")]
    [($src | path join "vendored-licenses" "AdaptiveCpp-LICENSE"), ($src | path join "AdaptiveCpp" "LICENSE")]
  ] ++ (if (($src | path join "rocm-dist") | path exists) {
    [
      [($src | path join "vendored-licenses" "rocm" "hip-LICENSE.md"), ($src | path join "rocm-dist" "share" "doc" "hip" "LICENSE.md")]
      [($src | path join "vendored-licenses" "rocm" "rocr-LICENSE.md"), ($src | path join "rocm-dist" "share" "doc" "rocr" "LICENSE.md")]
      [($src | path join "vendored-licenses" "rocm" "amd_comgr-LICENSE.txt"), ($src | path join "rocm-dist" "share" "doc" "amd_comgr" "LICENSE.txt")]
      [($src | path join "vendored-licenses" "rocm" "rocprofiler-register-LICENSE.md"), ($src | path join "rocm-dist" "share" "doc" "rocprofiler-register" "LICENSE.md")]
    ]
  } else { [] })) {
    if ((open --raw $pair.0 | str replace --all "\r" "") != (open --raw $pair.1 | str replace --all "\r" "")) {
      error make {msg: $"vendored license ($pair.0) differs from source tree ($pair.1) — update packages/_shared/licenses/"}
    }
  }
}

# clangdev/build.sh's post-install section, unix. Everything here shapes the
# tree the slicer packages carve, so it belongs to the BUILD half of the seam:
# upstream does it in its build script, not in an install/slice script.
#
# NOTE the version parse is GONE. Upstream computes MAJOR_VERSION from
# PKG_VERSION; for us PKG_VERSION is the stage's fixed 0.0.0, and inherited
# version-parsing in a lane whose version is not the software's version is the
# exact class of bug that put a YEAR into a clang resource-dir path on win. The
# major arrives from the recipe as ACPP_LLVM_MAJOR.
def clang-install-fixups-unix [prefix: string] {
  let major = $env.ACPP_LLVM_MAJOR
  let maj_min = $env.ACPP_LLVM_MAJ_MIN
  let bin = ($prefix | path join "bin")
  let target = (target-triple)
  let target_no_ver = (target-triple-no-ver)

  # Re-version the auxiliary clang-* drivers, leaving a symlink at the
  # unversioned name. clang-offload-packager-* is skipped upstream because it
  # links to llvm-offload-binary; clang-<major> is skipped because the install
  # already created it.
  for f in (glob $"($bin)/clang-*") {
    let name = ($f | path basename)
    if ($name | str starts-with "clang-offload-packager-") { continue }
    if $name == $"clang-($major)" { continue }
    if ($name | str ends-with $"-($major)") { continue }
    let versioned = ($bin | path join $"($name)-($major)")
    if ($versioned | path exists) { rm -f $versioned }
    mv $f $versioned
    ^ln -s $versioned $f
  }

  for n in [clang clang-cpp clang-cl "clang++"] {
    let p = ($bin | path join $n)
    if ($p | path exists) { rm -f $p }
  }
  let real = ($bin | path join $"clang-($major)")
  for n in ["c++" cc cpp clang "clang++" clang-cl clang-cpp $"clang++-($major)" $"clang-cl-($major)" $"clang-cpp-($major)"
            $"($target)-clang" $"($target)-clang++" $"($target)-clang-cpp"] {
    ^ln -sf $real ($bin | path join $n)
  }
  ^ln -sf ($bin | path join $"clang-scan-deps-($major)") ($bin | path join $"($target)-clang-scan-deps")

  let resource_dir = ($prefix | path join "lib" "clang" $major)
  if not (($resource_dir | path join "include") | path exists) {
    error make {msg: $"($resource_dir)/include not found"}
  }
  # Make sure omp.h from the conda environment is found by clang.
  ^ln -sf ($prefix | path join "include" "omp.h") ($resource_dir | path join "include" "omp.h")

  # Link the versioned libLTO into the versioned resource dir. The unversioned
  # symlink lives in llvmdev, which may not be installed when clang is, and
  # the system linker rejects any LTO library not named libLTO.dylib. Patch
  # 0011 is what makes clang look here.
  if (is-darwin) {
    mkdir ($resource_dir | path join "lib")
    ^ln -sf ($prefix | path join "lib" $"libLTO.($maj_min).dylib") ($resource_dir | path join "lib" "libLTO.dylib")
  }

  # The conda config files that make clang prefix-aware. Their PRESENCE is what
  # distinguishes upstream's `clang` (default_cfg_*) from `clang-no-conda-cfg`
  # (default_nocfg_*), so they are a packaging seam as well as a build output.
  for driver in [clang "clang++" clang-cpp] {
    "-isystem <CFGDIR>/../include\n" | save -f ($bin | path join $"($target_no_ver)-($driver).cfg")
  }
  for driver in [clang "clang++" flang] {
    let cfg = ($bin | path join $"($target_no_ver)-($driver).cfg")
    let extra = (if (is-darwin) {
      "$-Wl,-L,<CFGDIR>/../lib\n$-Wl,-rpath,<CFGDIR>/../lib\n"
    } else {
      "$-Wl,-L,<CFGDIR>/../lib\n$-Wl,-rpath,<CFGDIR>/../lib\n$-Wl,-rpath-link,<CFGDIR>/../lib\n"
    })
    let head = (if ($cfg | path exists) { open --raw $cfg } else { "" })
    $"($head)($extra)" | save -f $cfg
  }
  if not (is-darwin) {
    for driver in [clang "clang++" flang clang-cpp] {
      let cfg = ($bin | path join $"($target_no_ver)-($driver).cfg")
      let head = (if ($cfg | path exists) { open --raw $cfg } else { "" })
      $"($head)--sysroot=<CFGDIR>/../($target)/sysroot\n" | save -f $cfg
    }
  }
}

# clangdev/build.bat's post-install section, windows.
def clang-install-fixups-win [layout_root: string] {
  let major = $env.ACPP_LLVM_MAJOR
  let bin = ($layout_root | path join "bin")
  for n in [$"clang-($major).exe" $"clang++-($major).exe"] {
    let dest = ($bin | path join $n)
    if not ($dest | path exists) { cp -P ($bin | path join "clang.exe") $dest }
  }
  # libclang's SOVERSION is 13 and has been decoupled from the LLVM major since
  # LLVM 14 ("the ABI of libclang doesn't necessarily match the major version
  # anymore" — clangdev's own conda_build_config). Patch 0007 sets it
  # unconditionally, so the built DLL carries that number on win too.
  let versioned = ($bin | path join "libclang-13.dll")
  if not ($versioned | path exists) {
    error make {msg: $"($versioned) not found — libclang SOVERSION changed; check clangdev patch 0007 and libclang_soversion"}
  }
  ^create-forwarder-dll $versioned ($bin | path join "libclang.dll") --no-temp-dir

  let resource_dir = ($layout_root | path join "lib" "clang" $major)
  cp -P ($layout_root | path join "include" "omp.h") ($resource_dir | path join "include" "omp.h")
}

# openmp/install_pkg.sh, unix.
def openmp-install-fixups [prefix: string] {
  let libdir = ($prefix | path join "lib")
  for f in (glob $"($libdir)/libgomp*") { rm -f $f }
  if not (is-darwin) {
    let archer = ($libdir | path join "libarcher.so")
    # "move libarcher.so so that it doesn't interfere"
    if ($archer | path exists) { mv $archer ($libdir | path join "libarcher.so.bak") }
  }
}

# ============================================================================
def main [] {
  # THE STAGE-EXECUTION COUNTER, and it is an OBSERVATION, not a gate.
  #
  # The whole cost model of this workspace rests on one claim: the expensive
  # build runs ONCE per platform and every slicer reuses it through pixi's
  # .pixi/bld cache. That claim has never been measured on a real runner, and
  # it cannot be measured from inside the build tree — each build gets its own
  # copy of it. So each execution appends ONE line that cannot collide with
  # another execution's, to a file the workflow puts OUTSIDE the tree; the
  # number of DISTINCT lines is the number of times this script actually ran.
  # If the variable is unset (a local build, a laptop), nothing happens.
  let run_log = ($env | get -o ACPP_STAGE_RUN_LOG | default "")
  if $run_log != "" {
    let stamp = $"(date now | format date '%Y-%m-%dT%H:%M:%S%.9f') (random chars --length 12)"
    $"($stamp)\n" | save --append --raw $run_log
    print $"stage-execution counter: appended ($stamp) to ($run_log)"
  }

  # Empty values forwarded from the recipe env mean "unset" — hide them so the
  # tools fall back to their own defaults instead of seeing "".
  for v in [CCACHE_DIR CCACHE_MAXSIZE CCACHE_BASEDIR CCACHE_NOHASHDIR ACPP_BUILD_DIR] {
    if ($env | get -o $v | default "") == "" { hide-env --ignore-errors $v }
  }
  let src = $env.SRC_DIR
  let llvm_src = ($src | path join "llvm-project")

  check-licences $src

  # llvmdev/build.sh, unix, verbatim: "Make osx work like linux." Applied on
  # every unix platform upstream, not just osx.
  if not (is-windows) {
    let addllvm = ($llvm_src | path join "llvm" "cmake" "modules" "AddLLVM.cmake")
    open --raw $addllvm
      | str replace --all "NOT APPLE AND NOT ARG_SONAME" "NOT ARG_SONAME"
      | str replace --all "NOT APPLE AND ARG_SONAME" "ARG_SONAME"
      | save -f $addllvm
  }

  # openmp/build.sh, linux: "Make sure libomptarget does not link to
  # libLLVM.so". Kept even though OPENMP_ENABLE_LIBOMPTARGET is OFF for us —
  # lifting it costs nothing and losing it would be invisible the day that flag
  # moves.
  if (not (is-windows)) and (not (is-darwin)) {
    for f in (glob $"(fwd ($llvm_src | path join 'openmp'))/**/CMakeLists.txt") {
      open --raw $f
        | str replace --all "LLVM_LINK_LLVM_DYLIB" "LLVM_LINK_LLVM_DYLIB2"
        | str replace --all "NO_INSTALL_RPATH" "NO_INSTALL_RPATH DISABLE_LLVM_LINK_LLVM_DYLIB"
        | save -f $f
    }
  }

  # Conda's Windows layout puts headers/libs/binaries under %PREFIX%\Library,
  # so that — not $PREFIX — is the install prefix and the dependency root on
  # Windows. On Linux and macOS the two are the same.
  let layout_root = (if (is-windows) { $env.LIBRARY_PREFIX? | default ($env.PREFIX | path join "Library") } else { $env.PREFIX })

  # THE STAGE SUBDIRECTORY. This build installs into <layout_root>/_stage and
  # each carving subpackage copies ITS OWN portion up to the top level. Two
  # reasons, both structural:
  #
  #  1. A conda package IS the file diff of its build. A subpackage receives
  #     this stage as a HOST dependency, so everything the stage installed is
  #     already present in its $PREFIX and is therefore NOT new — nothing would
  #     be captured. Installing one level down makes the copy-to-top BE the
  #     diff.
  #  2. It replaces rattler-build's `staging:` output, which pixi's
  #     rattler-build backend cannot use: a staging output's dependency solve
  #     receives no channels at all, so a stage with real build/host deps
  #     cannot resolve.
  #
  # LAYOUT MIRROR — LOAD-BEARING, DO NOT "TIDY". The stage's internal layout
  # must mirror the final prefix layout exactly (_stage/bin, _stage/lib,
  # _stage/include, _stage/libexec, _stage/share). Binaries are linked with
  # $ORIGIN-relative rpaths, and those survive the copy to the top level ONLY
  # because _stage/bin -> _stage/lib has the same relative relationship as
  # bin -> lib. Copying to a different relative depth would break every binary.
  # The same invariance is what lets the clang driver find its resource
  # directory relative to its own executable. Measured, not theory.
  let prefix = ($layout_root | path join "_stage")
  mkdir $prefix
  let build = ($env.ACPP_BUILD_DIR? | default ($src | path join ".." "build_dir"))
  mkdir $build

  let sep = (if (is-windows) { ";" } else { ":" })
  $env.CMAKE_PREFIX_PATH = ($build + $sep + ($env.CMAKE_PREFIX_PATH? | default ""))
  $env.CCACHE_COMPILERCHECK = "content"

  if (is-windows) {
    # FindCUDA consults %CUDA_PATH% first: the toolkit is a HOST dep at the top
    # of the prefix, not in our stage dir.
    $env.CUDA_PATH = $layout_root
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
  # linux system-header failure and the win empty-arch failure. The outer build
  # sees identical flags via outer-flag-args; the child starts clean and gets
  # exactly what RUNTIMES_CMAKE_ARGS hands it.
  let flag_args = (outer-flag-args)
  # LDFLAGS deliberately STAYS in the env: inner ExternalProjects env-seed
  # their linker flags and NEED conda's -L$PREFIX/lib to resolve libLLVM's
  # NEEDED libs (libz/libzstd/libxml2). Linker flags were never the poison;
  # gcc-shaped COMPILE flags were, and those are stripped below.
  for v in [CFLAGS CXXFLAGS CPPFLAGS DEBUG_CFLAGS DEBUG_CXXFLAGS] {
    hide-env --ignore-errors $v
  }

  # The compiler activation package's own cmake argument set: triplet
  # binutils, install layout, and CMAKE_FIND_ROOT_PATH* carrying the sysroot.
  # Authoritative — passed FIRST, verbatim, with nothing added beside it, and
  # SPLATTED rather than quoted: conda-forge's own docs warn that quoting
  # ${CMAKE_ARGS} makes the shell treat it as a single argument.
  # Windows is excluded: that leg drives clang-cl + Ninja by hand, and the VS
  # activation's CMAKE_ARGS is aimed at MSVC generators.
  let activation_args = (if (is-windows) { [] } else {
    $env.CMAKE_ARGS? | default "" | split row -r '\s+' | where {|a| $a != "" }
  })

  let args = ($activation_args
    | append (common-args $src $prefix $layout_root $build)
    | append $flag_args
    | append (if (is-windows) {
        (windows-args $src $layout_root $build)
      } else if (is-darwin) {
        (darwin-args $src $prefix)
      } else {
        (linux-args $src $prefix $layout_root)
      }))

  ^cmake ($llvm_src | path join "llvm") -G Ninja ...$args -B $build

  if (is-windows) {
    ^cmake --build $build --parallel (cpu-count)
  } else {
    # libLLVM must exist BEFORE the inner ExternalProjects link against it:
    # their inner cmake links the file directly, so the outer ninja has no rule
    # for it and high job counts race ahead of the link (invisible at -j16,
    # fatal at -j64). Windows builds the dylib too now, but its inner projects
    # do not link it, so the ordered target stays unix-only.
    ^cmake --build $build --target LLVM --parallel (cpu-count)
    ^cmake --build $build --parallel (cpu-count)
  }

  ^cmake --install $build

  # HOLLOW-RUNTIMES GUARD: the runtimes child-configure fails SOFT — a broken
  # child compiler yields "supported architectures: <empty>" and a technically
  # green build that ships no clang_rt libs (caught only by a package content
  # test, minutes later, with zero evidence). Fail HERE instead, with the
  # child's configure log dumped into the CI log.
  let rt_glob = (if (is-windows) {
    (fwd ($prefix | path join "lib" "clang" "**" "clang_rt.asan*"))
  } else if (is-darwin) {
    ($prefix | path join "lib" "clang" "**" "libclang_rt.asan*")
  } else {
    ($prefix | path join "lib" "clang" "**" "libclang_rt.asan*")
  })
  if ((glob $rt_glob | length) == 0) {
    dump-runtimes-logs $build
    error make {msg: "compiler-rt runtimes are HOLLOW (no asan artifacts installed) — child configure evidence dumped above"}
  }

  if (is-windows) {
    clang-install-fixups-win $layout_root
  } else {
    clang-install-fixups-unix $prefix
    openmp-install-fixups $prefix
    # Unversioned .so symlinks are dev-package files elsewhere in conda; the
    # versioned sonames are what the runtime needs. The slicers decide which
    # package each lands in, so the unversioned links are recreated there, not
    # here.
    for f in [libLLVM.so libLTO.so libRemarks.so libclang.so libclang-cpp.so] {
      let p = ($prefix | path join "lib" $f)
      if ($p | path exists) { rm $p }
    }
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

  # ROCm runtime deploy (linux-64): acpp's OWN hip deployment manifest names
  # exactly what the backend needs at runtime. The ROCm tree is a BUILD input
  # (the TheRock tarball source), so those pieces are deployed into the stage
  # here and carved into acpp-runtime-rocm. Entries already inside the prefix
  # ($ACPP_* placeholders — the backend's own files) are installed normally and
  # skipped. Symlink families are preserved: the manifest names find_library's
  # answer (the unversioned dev name) while DT_NEEDED resolves the SONAME, so
  # both must exist.
  if (not (is-windows)) and (not (is-darwin)) and $nu.os-info.arch != "aarch64" {
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
          cp -P $f ($destdir | path join $name)
        }
      }
      print $"rocm deploy: ($pattern) -> ($destdir), (($matches | length)) files"
    }
  }

  ^ccache --show-stats
}
