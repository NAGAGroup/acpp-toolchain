# install_llvm.nu — the llvmdev family's slice, branching on $PKG_NAME.
#
# LIFTED FROM llvmdev-feedstock's `recipe/install_llvm.sh` / `install_llvm.bat`
# (vendored verbatim in the reference monolith at recipe/llvmdev/). llvmdev is
# one of the four feedstocks that does NOT slice with globs: one script installs
# to a temporary prefix and then moves a different subset per package name. The
# script IS the slice, so it is preserved as a script, with one arm per name,
# rather than translated into glob lists — translating it would be exactly the
# unverifiable judgement this rework exists to remove.
#
# THE ONE STRUCTURAL CHANGE, and it is forced: every upstream arm opens with
# `cmake --install ./build --prefix=./temp_prefix`, re-installing from a BUILD
# TREE. A slicer has no build tree — it has `_acpp-stage` as a host dependency,
# already installed under <layout_root>/_stage. So **_stage IS temp_prefix**,
# and everything after that line is lifted operation for operation.
#
# WHY `llvmdev` CAN SAY "EVERYTHING ELSE". Upstream declares `libllvm<major>`
# and `llvm-tools` as HOST dependencies of `llvmdev`, so their files are already
# in the prefix when llvmdev builds and a conda package is the file DIFF of its
# build — the remainder is what is left. We keep those host deps, so the same
# subtraction happens for the same reason. The `if already present, skip` test
# below is that mechanism made explicit rather than a second policy.
#
# NO VERSION PARSING. Upstream computes MAJOR_VER/SOVER_EXT/MAJOR_EXT by
# splitting PKG_VERSION. Inherited version-parsing is the class of bug that put
# a YEAR into a clang resource-dir path, so the values arrive from the recipe as
# ACPP_LLVM_MAJOR / ACPP_LLVM_MAJ_MIN. The rc/dev suffix branches upstream
# carries do not apply: we build tagged releases only.

# THE UNION-STAGE SCOPING DEFECT, and how arms 3/4/5 answer it.
#
# Upstream's file slices are scoped by their feedstock's BUILD: llvmdev's
# build.sh configures ../llvm with no LLVM_ENABLE_PROJECTS, so in ITS prefix
# `bin/*` means "llvm's tools" and nothing else. `_acpp-stage` is ONE cmake
# install of llvm + clang + clang-tools-extra + lld + lldb + openmp +
# compiler-rt + AdaptiveCpp, which removes exactly that scoping: against our
# stage `bin/*` also selects clang, clang-format, clangd, lld, lldb and acpp,
# every one of which is a different package of ours.
#
# So for these three arms the glob was never the contract — the SHIPPED SET is,
# and it is published. The lists below are derived from conda-forge's own
# 21.1.8 artifacts, read with `tools/upstream-paths.nu`, not from upstream's
# globs. Re-derive with:
#
#   pixi run -e dev nu tools/upstream-paths.nu llvm-tools-21 21.1.8 linux-64
#   pixi run -e dev nu tools/upstream-paths.nu llvm-tools    21.1.8 <platform>
#   pixi run -e dev nu tools/upstream-paths.nu llvmdev       21.1.8 <platform>

# Arms 3 and 4 ship the SAME 80 tool names — measured: the `-21` artifact's
# names with the suffix stripped are set-equal to the unsuffixed artifact's
# names, on linux-64 and on osx-arm64 both, and win-64's llvm-tools set is
# identical to linux-64's. So one list serves both arms and all platforms.
#
# `llvm-config` is deliberately absent: it belongs to llvmdev, and upstream
# spends an `rm` at the end of each arm to take it back out. A positive list
# never adds it, so those two `rm` steps are gone rather than reproduced.
# ⚠ EVERY GLOB GOES THROUGH THIS. On Windows `path join` emits BACKSLASHES,
# and a backslash is an ESCAPE character in a nushell glob pattern — so a
# pattern built from `path join` does not merely fail to match, it fails to
# PARSE (`failed to parse glob expression`, win run 34129107780). Forward
# slashes are valid separators on Windows, so normalising is safe everywhere
# and is done on every platform rather than under an `if windows`, which would
# leave the win path untested on linux.
#
# It also ASSERTS the result is clean: a backslash surviving normalisation
# means the pattern carried an intentional escape, which nothing here wants,
# and that assertion fires on ANY platform — including a linux laptop, where
# `path join` would never have produced one.
def glob-native [pattern: string, --no-dir] {
  # Strip Windows' VERBATIM prefix FIRST. `path expand` calls Rust's canonicalize,
  # which on Windows returns extended-length paths like `\\?\C:\bld\...`, and no
  # glob parser handles those. nushell#15707 reports exactly this shape: a
  # pattern built from `path expand`/`path join` fails to parse while the same
  # path written as a literal works — which is why "backslash is an escape" is
  # only half the story. Our own prefix and build dir go through `path expand`,
  # so this is the form we would meet.
  let p = ($pattern | str replace '\\?\' '' | str replace --all '\' '/')
  if ($p | str contains '\') {
    error make {msg: $"glob-native: pattern still contains a backslash after normalisation: ($p)"}
  }
  if $no_dir { glob $p --no-dir } else { glob $p }
}

const LLVM_TOOLS = [
    "bugpoint" "dsymutil" "llc" "lli"
    "llvm-addr2line" "llvm-ar" "llvm-as" "llvm-bcanalyzer"
    "llvm-bitcode-strip" "llvm-c-test" "llvm-cat" "llvm-cfi-verify"
    "llvm-cgdata" "llvm-cov" "llvm-ctxprof-util" "llvm-cvtres"
    "llvm-cxxdump" "llvm-cxxfilt" "llvm-cxxmap" "llvm-debuginfo-analyzer"
    "llvm-debuginfod" "llvm-debuginfod-find" "llvm-diff" "llvm-dis"
    "llvm-dlltool" "llvm-dwarfdump" "llvm-dwarfutil" "llvm-dwp"
    "llvm-exegesis" "llvm-extract" "llvm-gsymutil" "llvm-ifs"
    "llvm-install-name-tool" "llvm-jitlink" "llvm-jitlistener" "llvm-lib"
    "llvm-libtool-darwin" "llvm-link" "llvm-lipo" "llvm-lto"
    "llvm-lto2" "llvm-mc" "llvm-mca" "llvm-ml"
    "llvm-ml64" "llvm-modextract" "llvm-mt" "llvm-nm"
    "llvm-objcopy" "llvm-objdump" "llvm-opt-report" "llvm-otool"
    "llvm-pdbutil" "llvm-profdata" "llvm-profgen" "llvm-ranlib"
    "llvm-rc" "llvm-readelf" "llvm-readobj" "llvm-readtapi"
    "llvm-reduce" "llvm-remarkutil" "llvm-rtdyld" "llvm-sim"
    "llvm-size" "llvm-split" "llvm-stress" "llvm-strings"
    "llvm-strip" "llvm-symbolizer" "llvm-tblgen" "llvm-tli-checker"
    "llvm-undname" "llvm-windres" "llvm-xray" "opt"
    "reduce-chunk-list" "sancov" "sanstats" "verify-uselistorder"
]

# osx-arm64 ships 79 of the 80. `llvm-jitlistener` is built only under
# LLVM_USE_INTEL_JITEVENTS, which our own build-stage.nu sets on linux (line
# 191) and win (line 353) and not on osx — the same split conda-forge makes,
# confirmed in its artifacts: libLLVMIntelJITEvents is present in llvmdev on
# linux-64 and win-64 and absent on osx-arm64. So this is a property of the
# stage we actually build, not just of upstream's.
const LLVM_TOOLS_NOT_ON_DARWIN = ["llvm-jitlistener"]

def is-windows [] { $nu.os-info.name == "windows" }
def is-darwin [] { $nu.os-info.name == "macos" }
def slashes [] { str replace --all '\' '/' }
def shlib-ext [] { if (is-darwin) { ".dylib" } else { ".so" } }

# Copy one stage path to the same relative path at the top of the layout root.
# Identical relative depth is what keeps $ORIGIN/../lib and the clang driver's
# resource-dir lookup valid. `cp -P` preserves symlinks: `-p` is --progress and
# cp DEREFERENCES by default, which turns an LLVM symlink farm into gigabytes.
def place [src: string, layout_root: string, stage: string, dest_rel?: string] {
  let rel = (if $dest_rel == null { ($src | path relative-to $stage) } else { $dest_rel })
  let dst = ($layout_root | slashes | path join $rel)
  mkdir ($dst | path dirname)
  cp -P $src $dst
}

# The tool set for THIS platform. A positive list is only a safety improvement
# if a name it claims but cannot find is an error, so `require` below is what
# makes it one: silently shipping 79 tools where 80 were promised is the same
# class of quiet defect as over-selecting.
def llvm-tools-here [] {
  if (is-darwin) {
    $LLVM_TOOLS | where {|t| $t not-in $LLVM_TOOLS_NOT_ON_DARWIN }
  } else {
    $LLVM_TOOLS
  }
}

# Assert a stage path exists and return it. The message names the package's own
# vocabulary ("the slice has rotted against the stage") because the cause is
# always one of two things: the stage's cmake configuration changed, or upstream
# changed what it ships and our derived list is stale.
def require [p: string, what: string] {
  if not ($p | path exists) {
    error make {msg: $"install_llvm: ($what) is in this package's published file set but is not in the stage at ($p) — the slice has rotted against the stage"}
  }
  $p
}

# Copy a whole directory, file by file, preserving relative depth. Returns the
# count placed and fails on an empty tree, so a directory that moved upstream is
# loud rather than a silently thinner package.
def place-tree [dir: string, layout_root: string, stage: string] {
  if not ($dir | path exists) {
    error make {msg: $"install_llvm: ($dir) is in this package's published file set but is not in the stage — the slice has rotted against the stage"}
  }
  mut n = 0
  for f in (glob-native $"($dir)/**/*") {
    if (($f | path type) == "dir") { continue }
    place $f $layout_root $stage
    $n = $n + 1
  }
  if $n == 0 {
    error make {msg: $"install_llvm: ($dir) exists but is empty — the slice has rotted against the stage"}
  }
  $n
}

def main [] {
  let exe = (if (is-windows) { ".exe" } else { "" })
  let layout_root = (if (is-windows) {
    $env.LIBRARY_PREFIX? | default ($env.PREFIX | path join "Library")
  } else {
    $env.PREFIX
  })
  let stage = ($layout_root | path join "_stage" | slashes)
  if not ($stage | path exists) {
    error make {msg: $"install_llvm: stage directory ($stage) does not exist — is _acpp-stage a host dependency of this package?"}
  }

  let name = ($env.PKG_NAME? | default "")
  let major = $env.ACPP_LLVM_MAJOR
  let sover = $env.ACPP_LLVM_MAJ_MIN
  let ext = (shlib-ext)
  mut placed = 0

  if ($name | str starts-with "acpp-libllvm-c") {
    # -- upstream arm 1: only libLLVM-C --
    if (is-windows) {
      place $"($stage)/bin/LLVM-C.dll" $layout_root $stage
      place $"($stage)/lib/LLVM-C.lib" $layout_root $stage
      $placed = 2
    } else {
      for f in (glob-native $"($stage)/lib/libLLVM-C($sover)($ext)") {
        place $f $layout_root $stage
        $placed = $placed + 1
      }
    }
  } else if ($name | str starts-with "acpp-libllvm") {
    # -- upstream arm 2: LLVM's own shared libraries --
    #
    # ⚠ NAMED, NOT WILDCARDED, AND THAT IS THE WHOLE POINT. Upstream writes
    # `lib/lib*.so.<sover>`, which is correct in ITS prefix: llvmdev-feedstock
    # builds LLVM alone, so the only libraries carrying that soversion are
    # LLVM's. Our stage is a UNION of llvm, clang, lldb and openmp, where the
    # same glob also matches libclang-cpp.so.21.1, liblldb.so.21.1 and
    # liblldbIntelFeatures.so.21.1 — three libraries belonging to other
    # packages.
    #
    # That is not hypothetical: acpp-libllvm21 shipped libclang-cpp.so.21.1, and
    # because it is a HOST dependency of acpp-libclang-cpp21.1 the file was
    # already in the prefix when that package's carve ran — so the carve
    # reported "copied 1 files" while rattler counted "0 content" and the
    # package shipped empty (runs 34116494098 and 34118069537).
    #
    # SCOPED FROM THE ARTIFACT, like every other slice here. conda-forge's
    # libllvm21-21.1.8 ships exactly four paths on linux — libLLVM-21.so,
    # libLLVM.so.21.1, libLTO.so.21.1, libRemarks.so.21.1 — and the same four
    # on osx with dylib spelling. Fetched, not remembered:
    # `nu tools/upstream-paths.nu libllvm21 21.1.8 linux-64`.
    #
    # Same law as compiler-rt21's resource-dir subtree: an upstream glob that
    # is exact in a single-project prefix over-selects in our union stage.
    let versioned = (if (is-darwin) {
      [$"libLLVM.($sover).dylib" $"libLTO.($sover).dylib" $"libRemarks.($sover).dylib"]
    } else {
      [$"libLLVM.so.($sover)" $"libLTO.so.($sover)" $"libRemarks.so.($sover)"]
    })
    let pats = ([$"($stage)/lib/libLLVM-($major)($ext)"]
      | append ($versioned | each {|n| $"($stage)/lib/($n)" }))
    for p in $pats {
      for f in (glob-native $p) {
        place $f $layout_root $stage
        $placed = $placed + 1
      }
    }
  } else if $name == $"acpp-llvm-tools-($major)" {
    # -- upstream arm 3: each tool copied WITH a -<major> suffix.
    #    Upstream globs `bin/*`; against our union stage that also mints
    #    bin/clang-21, bin/clangd-21, bin/lld-21, bin/lldb-21, bin/acpp-21 —
    #    names LLVM never had — and bin/clang-format-21, which IS
    #    acpp-clang-format-21. Scoped to the published set instead. --
    for tool in (llvm-tools-here) {
      place (require $"($stage)/bin/($tool)($exe)" $tool) $layout_root $stage $"bin/($tool)-($major)($exe)"
      $placed = $placed + 1
    }
  } else if $name == "acpp-llvm-tools" {
    # -- upstream arm 4: the unsuffixed names. On unix a symlink farm onto the
    #    -<major> binaries; on win real copies, because Windows has no usable
    #    symlink here. Same scoping fix as arm 3: the bare glob claimed
    #    bin/clang, bin/clang++, bin/clang-format, bin/clangd, bin/lld and
    #    bin/acpp, clobbering five of our packages and acpp itself. --
    for tool in (llvm-tools-here) {
      if (is-windows) {
        place (require $"($stage)/bin/($tool)($exe)" $tool) $layout_root $stage
      } else {
        require $"($stage)/bin/($tool)" $tool
        let dst = ($layout_root | slashes | path join $"bin/($tool)")
        mkdir ($dst | path dirname)
        # RELATIVE target, where upstream writes ${PREFIX}/bin/... . Both names
        # live in bin/, so a bare basename resolves, and it keeps working after
        # the prefix is relocated — an absolute target baked at build time does
        # not, and conda's prefix rewriting does not touch symlink targets.
        ^ln -sf $"($tool)-($major)" $dst
      }
      $placed = $placed + 1
    }
    # share/opt-viewer belongs to llvm-tools on linux-64 and to llvmdev on
    # osx-arm64 and win-64. That split is upstream's, verified in the 21.1.8
    # artifacts of both packages on all three platforms, and it is followed
    # rather than normalised so each of our packages ships what its twin does.
    # (osx's llvm-tools additionally ships the same five scripts FLAT under
    # share/; that is an artefact of conda-forge's osx build, not a path any
    # LLVM install produces, so it is not reproduced.)
    if (not (is-windows)) and (not (is-darwin)) {
      $placed = $placed + (place-tree $"($stage)/share/opt-viewer" $layout_root $stage)
    }
  } else {
    # -- upstream arm 5, llvmdev: upstream says "everything else" and relies on
    #    its host deps having already filled the prefix. That subtraction is
    #    only safe in a single-project prefix: against our union stage the
    #    remainder also contains clangdev's headers and static libs, lld, lldb,
    #    compiler-rt and acpp — none of which llvmdev's host deps cover. So the
    #    slice is a POSITIVE list of what conda-forge's llvmdev artifact ships,
    #    which is a small, regular set: llvm-config, the llvm/llvm-c headers,
    #    llvm's cmake package, the LLVM* static libs, the unversioned developer
    #    symlinks for the shared libs, and libexec/llvm. --
    let lib = ($stage | path join "lib")

    # bin: llvm-config everywhere; win additionally ships the two DLLs whose
    # import libraries are below (on unix those are lib/*.so|dylib symlinks).
    place (require $"($stage)/bin/llvm-config($exe)" "llvm-config") $layout_root $stage
    $placed = $placed + 1
    if (is-windows) {
      for d in ["LTO.dll" "Remarks.dll"] {
        place (require $"($stage)/bin/($d)" $d) $layout_root $stage
        $placed = $placed + 1
      }
    }

    # headers: exactly the two trees the artifact carries. `include/**` would
    # additionally take clang/, clang-c/, lld/, lldb/ and openmp's omp.h.
    for d in ["llvm" "llvm-c"] {
      $placed = $placed + (place-tree $"($stage)/include/($d)" $layout_root $stage)
    }

    # cmake: llvm/ only — the stage also holds clang/, lld/ and lldb/.
    $placed = $placed + (place-tree $"($lib)/cmake/llvm" $layout_root $stage)

    # libexec: llvm/ only.
    $placed = $placed + (place-tree $"($stage)/libexec/llvm" $layout_root $stage)

    # static libs: every one llvmdev ships is LLVM-prefixed — measured, 208 of
    # 208 on linux-64 and osx-arm64, 208 of 208 on win-64. A bare lib/*.a would
    # also take clang's libclang*.a and lld's liblld*.a.
    let static_pat = (if (is-windows) { $"($lib)/LLVM*.lib" } else { $"($lib)/libLLVM*.a" })
    let statics = (glob-native $static_pat | where {|f| ($f | path basename) not-in ["LLVM-C.lib"] })
    if ($statics | is-empty) {
      error make {msg: $"install_llvm: no static libraries matched ($static_pat) — the llvmdev slice has rotted against the stage"}
    }
    for f in $statics { place $f $layout_root $stage; $placed = $placed + 1 }

    # The unversioned developer aliases. The VERSIONED objects belong to
    # libllvm<major>/libllvm-c<major> (arms 1 and 2); these are the -dev names a
    # linker resolves through. LLVM-C is excluded above and here: it is
    # acpp-libllvm-c21's whole content.
    let aliases = (if (is-windows) {
      ["LTO.lib" "Remarks.lib"]
    } else {
      [$"libLLVM($ext)" $"libLTO($ext)" $"libRemarks($ext)"]
    })
    for a in $aliases {
      place (require $"($lib)/($a)" $a) $layout_root $stage
      $placed = $placed + 1
    }

    # share/opt-viewer on the two platforms whose llvmdev artifact carries it.
    if (is-windows) or (is-darwin) {
      $placed = $placed + (place-tree $"($stage)/share/opt-viewer" $layout_root $stage)
    }
  }

  if $placed == 0 {
    error make {msg: $"install_llvm: the ($name) arm placed no files — the slice has rotted against the stage"}
  }
  print $"install_llvm: ($name) placed ($placed) files"
}