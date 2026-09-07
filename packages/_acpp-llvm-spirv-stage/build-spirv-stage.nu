# build-spirv-stage.nu — the ONE SPIRV-LLVM-Translator build.
#
# LIFTED FROM llvm-spirv-feedstock's `build.sh` / `bld.bat` and `install.sh` /
# `install.bat` (vendored in the reference monolith at recipe/llvm-spirv/).
# Upstream splits one build into four packages through a `staging:` output; we
# cannot, so this script IS that staging build and the four slicers read what it
# installs.
#
# WHERE IT INSTALLS: <layout_root>/_spirv-stage, a DISTINCT directory from the
# main stage's _stage, so the two can never merge in one prefix.
#
# WHAT IT BUILDS AGAINST: our own LLVM, inside _acpp-stage. LLVM_DIR is
# <layout_root>/_stage/lib/cmake/llvm — `lib/cmake/llvm`, not upstream's
# `cmake/llvm`, because that is where our artifact puts LLVMConfig.cmake on
# Windows. spirv-headers is a host dependency and sits at the layout root, not
# in the stage, so the two prefixes are named separately below. Without
# LLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR the translator's CMake runs
# FetchContent OVER GIT at configure time, which a conda build must not do.
#
# BUILD_SHARED_LIBS FOLLOWS UPSTREAM'S OWN SPLIT: `yes` on unix (build.sh),
# unset on win (bld.bat), where CMake defaults it OFF. That split is not
# incidental — it is exactly why upstream's libllvmspirv<major> output carries
# `skip: win` and why win's libllvmspirv ships a STATIC LLVMSPIRVLib.lib rather
# than an import library for a DLL.
#
# THE INSTALL FIXUP is upstream's install.sh / install.bat: rename the installed
# `llvm-spirv` to `llvm-spirv-<major>` and put the plain name back pointing at
# it. On unix that is a symlink; on WINDOWS upstream uses `mklink /h`, a HARD
# link, so two real files are shipped. Reproduced as written — a copy is the
# closest nushell equivalent of a hard link and produces the same two-real-files
# result the win artifacts show.

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

def is-windows [] { $nu.os-info.name == "windows" }
def slashes [] { str replace --all '\' '/' }
def cpu-count [] { $env.CPU_COUNT? | default (sys cpu | length) | into int }

# LICENCE-DRIFT GUARD, the same one _acpp-stage runs. The four slicers have no
# source tree, so their `license_file` points at the vendored copy under
# _shared/licenses/. This build is the only place that can see both it and the
# real licence in the extracted source, so a revision bump that changes the
# licence fails HERE instead of shipping stale text.
def check-licence [src: string] {
  let vendored = ($src | path join "vendored-licenses" "SPIRV-LLVM-Translator-LICENSE.TXT")
  let real = ($src | path join "LICENSE.TXT")
  if ((open --raw $vendored | str replace --all "\r" "") != (open --raw $real | str replace --all "\r" "")) {
    error make {msg: $"vendored license ($vendored) differs from source tree ($real) — update packages/_shared/licenses/"}
  }
}

def main [] {
  let layout_root = (if (is-windows) {
    $env.LIBRARY_PREFIX? | default ($env.PREFIX | path join "Library")
  } else {
    $env.PREFIX
  } | slashes)

  let llvm_stage = ($layout_root | path join "_stage")
  let prefix = ($layout_root | path join "_spirv-stage")
  let major = $env.ACPP_LLVM_MAJOR
  let src = ($env.SRC_DIR | slashes)

  if not (($llvm_stage | path join "lib" "cmake" "llvm") | path exists) {
    error make {msg: $"build-spirv-stage: ($llvm_stage)/lib/cmake/llvm does not exist — is _acpp-stage a host dependency of this package?"}
  }
  check-licence $src

  # CMAKE_ARGS carries the compiler activation's own flags and must be passed
  # through, as both upstream scripts do.
  let cmake_args = ($env.CMAKE_ARGS? | default "" | split row " " | where {|a| $a != "" })

  let args = ($cmake_args | append [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DLLVM_SPIRV_BUILD_EXTERNAL=YES"
    $"-DLLVM_DIR=($llvm_stage)/lib/cmake/llvm"
    $"-DCMAKE_INSTALL_PREFIX=($prefix)"
    # Both roots: LLVM comes out of the stage, spirv-headers and zlib out of the
    # ordinary host prefix.
    $"-DCMAKE_PREFIX_PATH=($llvm_stage);($layout_root)"
    $"-DLLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR=($layout_root)"
    # We do not run the translator's lit suite, and leaving it on drags in llvm
    # test components at configure time.
    "-DLLVM_SPIRV_INCLUDE_TESTS=OFF"
  ] | append (if (is-windows) { [] } else { ["-DBUILD_SHARED_LIBS=yes"] }))

  ^cmake -S $src -B $"($src)/build" -G Ninja ...$args
  ^cmake --build $"($src)/build" --parallel (cpu-count)
  ^cmake --install $"($src)/build"

  # ---- upstream's install fixup ------------------------------------------
  let bin = ($prefix | path join "bin")
  let ext = (if (is-windows) { ".exe" } else { "" })
  let plain = ($bin | path join $"llvm-spirv($ext)")
  let versioned = ($bin | path join $"llvm-spirv-($major)($ext)")
  if not ($plain | path exists) {
    error make {msg: $"build-spirv-stage: the install produced no ($plain)"}
  }
  mv $plain $versioned
  if (is-windows) {
    # `mklink /h` upstream; two real files either way, which is what the
    # published win artifacts carry.
    cp $versioned $plain
  } else {
    ^ln -s $"llvm-spirv-($major)($ext)" $plain
  }

  # The four slicers name every path they ship, so a shape change here has to
  # be visible. Print the whole tree rather than a count.
  print "build-spirv-stage: installed tree —"
  for f in (glob-native $"($prefix)/**/*" | where {|p| ($p | path type) != "dir" } | sort) {
    print $"  ($f | path relative-to $prefix)"
  }
}