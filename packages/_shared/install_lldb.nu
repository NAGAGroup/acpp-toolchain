# install_lldb.nu — acpp-lldb's slice of the stage.
#
# LIFTED FROM lldb-feedstock's `build.sh` / `bld.bat` (vendored in the reference
# monolith at recipe/lldb/). Like lld and openmp, lldb is a single-package
# recipe with no `outputs:` and no `files:` — its package is "whatever the build
# installed" — so the script IS the slice and stays a script.
#
# SCOPE derived from conda-forge's PUBLISHED lldb-21.1.8 artifact:
#   pixi run -e dev nu tools/upstream-paths.nu lldb 21.1.8 <platform>
# 705 / 720 / 702 paths on linux-64 / osx-arm64 / win-64, of which ~650 are the
# public headers under include/lldb.
#
# ⚠ THIS PACKAGE IS THE ONE THAT SPANS BOTH WINDOWS ROOTS. Everything it ships
# lives under the layout root (%PREFIX%\Library) EXCEPT the Python bindings,
# which conda puts at %PREFIX%\Lib\site-packages — above the layout root, where
# the interpreter looks. On unix the two roots are the same directory and the
# distinction disappears. That split is exactly why lldb cannot use
# ../_shared/carve.nu: ACPP_CARVE_DEST chooses ONE destination for a whole
# package, and this package needs two. Upstream expresses the same split by
# passing `-DLLDB_PYTHON_RELATIVE_PATH=..\Lib\site-packages`; see the note in
# _acpp-stage/build-stage.nu for why our stage drops the `..`.
#
# THE PYTHON VERSION IS READ OFF THE STAGE, not off the variant. The bindings
# live under lib/python<maj>.<min>/site-packages on unix, and the stage is the
# thing that decided which interpreter they were compiled against. Finding
# exactly one such directory is also the check that the stage built them at all;
# zero or several is a defect and fails here.

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
# ⚠ ONE CANONICALISER FOR BOTH SIDES OF EVERY PATH COMPARISON.
# `path expand` makes a path absolute — on Windows that ADDS THE DRIVE LETTER,
# because nushell resolves `/tmp/x` against the current drive as `C:\tmp\x` —
# and canonicalize may return the verbatim `\\?\` prefix. Glob RESULTS come back
# expanded; a root built by hand does not. Win run 34135577725 failed on exactly
# that difference AFTER separators were already normalised: results
# `C:/tmp/stage-fixups-windows/...` against a root `/tmp/stage-fixups-windows`,
# and `path relative-to` cannot find a prefix that is missing a drive.
#
# nushell#15707's reporter stripped the drive letter to work around this;
# canonicalising BOTH sides keeps it, which is the answer that stays correct
# when the path is used for anything other than matching.
def canon-path [p: string] {
  $p | path expand | str replace '\\?\' '' | str replace --all '\' '/'
}

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
  # ⚠ AND THE RESULTS ARE NORMALISED TOO, which is the other half. On Windows
  # glob RETURNS backslash paths (or verbatim ones), so a caller comparing a
  # result against a forward-slash root — `path relative-to`, `str starts-with`,
  # `=~` — fails with `prefix not found` even though the pattern was fine. Win
  # run 34134434830 died in exactly that way, in the harness's own snapshot,
  # AFTER the fixups themselves had passed. Both sides of every comparison must
  # be forward-slash, and returning them normalised is the one place that makes
  # every caller correct at once.
  let hits = (if $no_dir { glob $p --no-dir } else { glob $p })
  $hits | each {|h| $h | str replace '\\?\' '' | str replace --all '\' '/' }
}

def is-windows [] { $nu.os-info.name == "windows" }
def is-darwin [] { $nu.os-info.name == "macos" }
def slashes [] { str replace --all '\' '/' }

def place [src: string, dest_root: string, stage: string] {
  let rel = ($src | path relative-to $stage)
  let dst = ($dest_root | slashes | path join $rel)
  mkdir ($dst | path dirname)
  cp -P $src $dst
}

def place-tree [rel: string, dest_root: string, stage: string, required: bool] {
  let src = ($stage | path join $rel)
  if not ($src | path exists) {
    if $required {
      error make {msg: $"install_lldb: ($rel) is a required part of this package and is not in the stage at ($src) — the slice has rotted against the stage"}
    }
    return 0
  }
  let files = (glob-native $"($src)/**/*" | where {|p| ($p | path type) != "dir" })
  if ($files | is-empty) {
    error make {msg: $"install_lldb: ($rel) exists in the stage but contains no files"}
  }
  for f in $files { place $f $dest_root $stage }
  $files | length
}

def main [] {
  let prefix = ($env.PREFIX | slashes)
  let layout_root = (if (is-windows) {
    $env.LIBRARY_PREFIX? | default ($prefix | path join "Library")
  } else {
    $prefix
  })
  let stage = ($layout_root | path join "_stage" | slashes)
  if not ($stage | path exists) {
    error make {msg: $"install_lldb: stage directory ($stage) does not exist — is _acpp-stage a host dependency of this package?"}
  }
  let ext = (if (is-darwin) { ".dylib" } else { ".so" })
  let maj_min = ($env.ACPP_LLVM_MAJ_MIN? | default "21.1")
  let ver = ($env.ACPP_LLVM_VERSION? | default "21.1.8")

  # THE DRIVERS. `darwin-debug` is osx-only and is what LLDB uses to launch a
  # process under a debugger on macOS; the artifact carries it and our stage
  # builds it, so it is required rather than optional there.
  let bins = (["lldb" "lldb-argdumper" "lldb-dap" "lldb-instr" "lldb-server"]
    | append (if (is-darwin) { ["darwin-debug"] } else { [] }))

  # THE SHARED LIBRARY, in its three names on unix (unversioned symlink,
  # soname, full version) and its DLL + import library on win.
  let libs = (if (is-windows) {
    ["bin/liblldb.dll" "lib/liblldb.lib"]
  } else if (is-darwin) {
    [$"lib/liblldb($ext)" $"lib/liblldb.($maj_min)($ext)" $"lib/liblldb.($ver)($ext)"]
  } else {
    [$"lib/liblldb($ext)" $"lib/liblldb($ext).($maj_min)" $"lib/liblldb($ext).($ver)"]
  })

  let required = ((if (is-windows) {
    $bins | each {|b| $"bin/($b).exe" }
  } else {
    $bins | each {|b| $"bin/($b)" }
  }) | append $libs)

  # OPTIONAL, and listed rather than guessed at. liblldbIntelFeatures is in
  # conda-forge's linux-64 artifact and in neither of the other two; it is built
  # from lldb's tools/intel-features, which hangs off a cmake option our stage
  # does not set explicitly. Absence is logged, not silently accepted, and that
  # log line is what this list should be tightened against on the first real
  # linux build — the same discipline acpp-llvm-openmp uses.
  let optional = (if (is-windows) or (is-darwin) { [] } else {
    [$"lib/liblldbIntelFeatures($ext)" $"lib/liblldbIntelFeatures($ext).($maj_min)"]
  })

  mut placed = 0
  for rel in $required {
    let src = ($stage | path join $rel)
    if not ($src | path exists) {
      error make {msg: $"install_lldb: ($rel) is a required part of this package and is not in the stage at ($src) — the slice has rotted against the stage"}
    }
    place $src $layout_root $stage
    $placed = $placed + 1
  }

  mut missing = []
  for rel in $optional {
    let src = ($stage | path join $rel)
    if ($src | path exists) {
      place $src $layout_root $stage
      $placed = $placed + 1
    } else {
      $missing = ($missing | append $rel)
    }
  }

  # The public headers: an lldb-owned directory, so a tree copy cannot reach
  # another project's output even in a union stage.
  $placed = $placed + (place-tree "include/lldb" $layout_root $stage true)

  # THE PYTHON BINDINGS, and the one place the destination is %PREFIX% rather
  # than the layout root.
  let sp_dirs = (if (is-windows) {
    glob-native $"($stage)/Lib/site-packages/lldb" | where {|p| ($p | path type) == "dir" }
  } else {
    glob-native $"($stage)/lib/python*/site-packages/lldb" | where {|p| ($p | path type) == "dir" }
  })
  if ($sp_dirs | length) != 1 {
    error make {msg: $"install_lldb: expected exactly one lldb python-bindings directory in the stage, found ($sp_dirs | length) — LLDB_ENABLE_PYTHON or LLDB_PYTHON_RELATIVE_PATH in build-stage.nu is not producing what this slice expects: ($sp_dirs)"}
  }
  let sp_rel = ($sp_dirs | first | slashes | path relative-to $stage)
  $placed = $placed + (place-tree $sp_rel $prefix $stage true)

  if ($missing | is-empty) {
    print "install_lldb: every optional path was present"
  } else {
    print $"install_lldb: OPTIONAL PATHS ABSENT FROM THE STAGE — ($missing | str join ', ')"
  }
  print $"install_lldb: placed ($placed) files \(python bindings from ($sp_rel))"
}