# build-stage.nu — the ONE LLVM+AdaptiveCpp build behind every package output.
#
# Sources are fetched by rattler-build into the work dir; the staging cache
# snapshots prefix+work_dir so the carving outputs never recompile. The CMake
# binary dir lives OUTSIDE the work dir so compile-command paths stay stable
# for ccache and a staging-cache miss can still reuse objects.
#
# Linux, macOS and Windows differ materially (upstream AdaptiveCpp only
# supports clang-cl on Windows, and the backend set differs per platform), so
# the CMake argument list is assembled per platform. LLVM itself is built as a
# dylib on EVERY platform (libLLVM.so / libLLVM.dylib / LLVM-<ver>.dll via
# LLVM_BUILD_LLVM_DYLIB_VIS on Windows), and every tool links it.
# The LLVM source is AMD's llvm-project snapshot (version suffix `git`, so the
# linux soname is libLLVM.so.23.0git), the commit TheRock's comgr is built on.

source build-stage-lib.nu

def main [] {
  # Empty values forwarded from the recipe env mean "unset" — hide them so the
  # tools fall back to their own defaults instead of seeing "".
  for v in [CCACHE_DIR CCACHE_MAXSIZE CCACHE_BASEDIR CCACHE_NOHASHDIR ACPP_BUILD_DIR] {
    if ($env | get -o $v | default "") == "" { hide-env --ignore-errors $v }
  }
  let src = $env.SRC_DIR
  # TheRock's tree (linux-64 and win-64 only), used by the licence guard and
  # the ROCm runtime deploy below; stage-args adds it to the find roots.
  let rocm = ($src | path join "rocm-dist")

  # License-drift guard: package outputs ship the VENDORED texts from
  # shared/licenses/ (they no longer carry the big source trees), so assert
  # the vendored copies are byte-identical to the licenses in the actually
  # extracted sources. A pin bump that changes a license fails HERE, loudly,
  # instead of silently shipping stale text.
  for pair in ([
    [($src | path join "shared" "licenses" "llvm-LICENSE.TXT"), ($src | path join "llvm-project" "LICENSE.TXT")]
    [($src | path join "shared" "licenses" "AdaptiveCpp-LICENSE"), ($src | path join "AdaptiveCpp" "LICENSE")]
  ] ++ (if (($src | path join "rocm-dist") | path exists) {
    # ROCm subset licences (linux-64 and win-64 — the tarball is that
    # platform's build input); vendored for acpp-runtime-rocm's license_file.
    # Each pair is checked only when its source file exists: the Windows
    # tarball ships share/doc/amd_comgr but NOT share/doc/hip, rocr or
    # rocprofiler-register, so those are skipped there (and reported).
    ([
      [($src | path join "shared" "licenses" "rocm" "hip-LICENSE.md"), ($src | path join "rocm-dist" "share" "doc" "hip" "LICENSE.md")]
      [($src | path join "shared" "licenses" "rocm" "rocr-LICENSE.md"), ($src | path join "rocm-dist" "share" "doc" "rocr" "LICENSE.md")]
      [($src | path join "shared" "licenses" "rocm" "amd_comgr-LICENSE.txt"), ($src | path join "rocm-dist" "share" "doc" "amd_comgr" "LICENSE.txt")]
      [($src | path join "shared" "licenses" "rocm" "rocprofiler-register-LICENSE.md"), ($src | path join "rocm-dist" "share" "doc" "rocprofiler-register" "LICENSE.md")]
    ] | where {|p|
      let present = ($p.1 | path exists)
      if not $present { print ("license check: skipped " + $p.1 + " (not in this platform's tarball)") }
      $present
    })
  } else { [] })) {
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

  # Capture the cmake arguments (they embed the conda flags for the OUTER
  # configure), then STRIP those flags from the environment: the runtimes child
  # cmake (spawned mid-build by ninja) seeds its flags from env CFLAGS/CXXFLAGS,
  # the pollution vector behind both the linux system-header failure and the win
  # empty-arch failure. The outer build sees identical flags via outer-flag-args;
  # the child starts clean and gets exactly what RUNTIMES_CMAKE_ARGS hands it.
  let args = (stage-args $src $prefix $build)
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


  ^cmake ($src | path join "llvm-project" "llvm") -G Ninja ...$args -B $build

  # The LLVM dylib must exist BEFORE AdaptiveCpp's SPIRV-LLVM-Translator
  # ExternalProject builds: its inner cmake links the file directly (libLLVM.so,
  # libLLVM.dylib, or the LLVM import library on Windows), so the outer ninja
  # has no rule for it and high job counts race ahead of the link (invisible at
  # -j16, fatal at -j64). Every platform builds the dylib now, so the same
  # ordering applies everywhere.
  ^cmake --build $build --target LLVM --parallel (cpu-count)
  ^cmake --build $build --parallel (cpu-count)

  cd $build
  ^cmake --install $build

  # HOLLOW-RUNTIMES GUARD: the runtimes child-configure fails SOFT — a broken
  # child compiler yields "supported architectures: <empty>" and a technically
  # green build that ships no clang_rt libs (caught only by the package
  # content test, 8 minutes later, with zero evidence). Fail HERE instead,
  # with the child's CMakeError.log dumped into the CI log.
  # NB backslashes are glob ESCAPES in nushell — normalize the joined path or
  # `glob` fails to parse on Windows (this crash ate a run's evidence).
  # Not on win-arm64 (builtins only there: no asan runtime to look for).
  # macOS builds the darwin sanitizers, so its asan dylib is checked too.
  if not ((is-windows) and (is-arm)) {
    let rt_glob = (if (is-windows) {
      ($prefix | path join "lib" "clang" "**" "clang_rt.asan*" | str replace --all '\' '/')
    } else {
      ($prefix | path join "lib" "clang" "**" "libclang_rt.asan*")
    })
    if ((glob $rt_glob | length) == 0) {
      dump-runtimes-logs $build
      error make {msg: "compiler-rt runtimes are HOLLOW (no asan artifacts installed) — child configure evidence dumped above"}
    }
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

  # ROCm runtime subset: ONLY these files come from TheRock's tarball (rocm-dist),
  # copied with the tarball's OWN layout so the discovered subdirs resolve
  # under the prefix (ACPP_HIP_ROOT=.). Nothing from its lib/llvm (no libLLVM,
  # libclang-cpp, clang, lld or tools), no .kpack/, no HIP/HSA headers: on
  # Linux libamd_comgr NEEDs libLLVM.so.23.0git and libclang-cpp.so.23.0git
  # (RUNPATH $ORIGIN first) and binds to OUR copies in the same lib/. The list
  # matches naga-acpp-runtime-rocm in recipe.yaml, file for file.
  if ($rocm | path exists) {
    if not (is-windows) {
      let libdir = ($prefix | path join "lib")
      # stem -> required? (SONAME symlink families are preserved by cp -a)
      for stem in [
        {n: amdhip64, req: true} {n: hsa-runtime64, req: true} {n: amd_comgr, req: true}
        {n: hiprtc, req: true} {n: hiprtc-builtins, req: true} {n: rocm_kpack, req: true}
        {n: rocprofiler-register, req: true}
      ] {
        let matches = (glob ($rocm | path join "lib" $"lib($stem.n).so*"))
        if ($matches | is-empty) {
          if $stem.req { error make {msg: $"rocm deploy: no lib($stem.n).so* under ($rocm)/lib"} }
          continue
        }
        ^cp -a ...$matches $libdir
        print $"rocm deploy: lib($stem.n): ($matches | length) files"
      }
      let sysdeps = ($rocm | path join "lib" "rocm_sysdeps")
      if not ($sysdeps | path exists) { error make {msg: $"rocm deploy: no rocm_sysdeps at ($sysdeps)"} }
      ^cp -a $sysdeps $libdir
      let bitcode = ($rocm | path join "lib" "llvm" "amdgcn" "bitcode")
      if not ($bitcode | path exists) { error make {msg: $"rocm deploy: no device bitcode at ($bitcode)"} }
      let bitcode_dest = ($prefix | path join "lib" "llvm" "amdgcn")
      mkdir $bitcode_dest
      ^cp -a $bitcode $bitcode_dest
      print $"rocm deploy: bitcode -> ($bitcode_dest)/bitcode"
    } else {
      let bindir = ($prefix | path join "bin")
      let rocm_bin = ($rocm | path join "bin")
      # amdhip64_7.dll, amd_comgr.dll, hiprtc0716.dll, hiprtc-builtins0716.dll, rocm_kpack.dll
      let dlls = (glob ($rocm_bin | path join "*.dll" | str replace --all '\' "/") | where {|f| ($f | path basename) =~ "^(amdhip64|amd_comgr|hiprtc|rocm_kpack)" })
      for need in [amdhip64 amd_comgr hiprtc hiprtc-builtins rocm_kpack] {
        if ($dlls | where {|f| ($f | path basename) | str starts-with $need } | is-empty) {
          print (ls $rocm_bin | get name | path basename | str join "\n")
          error make {msg: $"rocm deploy: no ($need)*.dll under ($rocm_bin)"}
        }
      }
      for f in $dlls { cp $f $bindir }
      print $"rocm deploy: ($dlls | length) DLLs -> ($bindir)"
      # their import libs
      let libs = (glob ($rocm | path join "lib" "*.lib" | str replace --all '\' "/") | where {|f| ($f | path basename) =~ "^(amdhip64|amd_comgr|hiprtc|rocm_kpack)" })
      if ($libs | is-empty) { error make {msg: "rocm deploy: no import libs for the ROCm DLLs"} }
      mkdir ($prefix | path join "lib")
      for l in $libs { cp $l ($prefix | path join "lib") }
      print $"rocm deploy: ($libs | length) import libs"
      let bc = ($rocm | path join "lib" "llvm" "amdgcn" "bitcode")
      if not ($bc | path exists) { error make {msg: $"rocm deploy: no amdgcn bitcode at ($bc)"} }
      let dest = ($prefix | path join "lib" "llvm" "amdgcn")
      mkdir $dest
      cp -r $bc $dest
      print $"rocm deploy: bitcode -> ($dest)/bitcode"
    }
  }

  # Clang config files (<triple>-clang{,++,-cpp}.cfg in bin/): bare clang
  # then finds --sysroot/-isystem/-L/-rpath with no activation script. Not on
  # Windows — clang-cl has no default-target cfg lookup, and the win compiler
  # activation story is a separate hand-off.
  if not (is-windows) {
    let cfg_triple = (if (is-darwin) { "arm64-apple-darwin20.0.0" } else { linux-triple })
    let has_sysroot = (if (is-darwin) { "false" } else { "true" })
    ^nu ($src | path join "shared" "activation" "install-cfg.nu") $cfg_triple $has_sysroot
  }

  # STAGING-CACHE DIET. rattler-build caches this whole work dir with the
  # staging output and, for EVERY inheriting output, deletes and recopies it
  # (twice per output: upstream process_staging_caches restores the inherited
  # cache in its loop and again for inherits_from). Measured on win-64 build 2:
  # 166,968 files per restore, 6-9 min each on D:. The source trees are ~150k
  # of those files and no output needs them: licenses ship from
  # shared/licenses (drift-checked at the top of this script) and the cmake
  # build dir is $SRC_DIR/../build_dir, outside the work dir. Keep shared/ —
  # the activation outputs copy from $SRC_DIR/shared. Best effort: a failed
  # delete costs speed, never correctness, so it warns instead of failing.
  for d in [llvm-project AdaptiveCpp OpenCL-Headers OpenCL-CLHPP metal-cpp rocm-dist] {
    let p = ($src | path join $d)
    if not ($p | path exists) { continue }
    try {
      rm --recursive --force $p
    } catch {
      # Windows: git objects are read-only; clear the attribute and retry.
      if (is-windows) { try { ^attrib -R ($p | path join "*") /S /D | ignore } }
      try { rm --recursive --force $p } catch {|e| print $"WARNING: could not prune ($p): ($e.msg)" }
    }
    if not ($p | path exists) { print $"staging diet: removed ($d)" }
  }

  if (which ccache | is-not-empty) { ^ccache --show-stats }
}
