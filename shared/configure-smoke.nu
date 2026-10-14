# configure-smoke.nu: free gate. CONFIGURE ONLY (never builds) the linux-64
# LLVM + AdaptiveCpp tree, with the cmake arguments produced by
# shared/build-stage-lib.nu's `stage-args` (sourced below, not copied), against
#   * the AMD llvm-project archive pinned in recipe.yaml,
#   * the NAGAGroup/AdaptiveCpp fork at the recipe's acpp_commit,
#   * the OpenCL headers pinned in recipe.yaml and TheRock's linux tarball
#     (hip_ROOT discovery).
# It catches option, path and version-gate errors in seconds instead of after
# a multi-minute download on a CI runner, and it reports every CMake message
# containing "deprecat" with its file:line. The runtimes children (compiler-rt,
# openmp) are configured by the BUILD with the just-built clang, so this gate
# cannot see them.
#
# Run it inside the smoke environment:  pixi run -e smoke configure-smoke
#   [--src <dir>]   scratch source root (default /tmp/acpp-configure-smoke);
#                   a component directory that already exists there is reused
#                   (llvm-project, AdaptiveCpp, OpenCL-Headers, OpenCL-CLHPP,
#                   rocm-dist), anything missing is fetched and sha256-checked.
#   [--keep-build]  keep an existing build dir (default: start from scratch).

# Brings in stage-args and every per-platform argument function: the same
# library build-stage.nu sources (it defines no `main`).
source build-stage-lib.nu

const HERE = (path self .)

# The first capture of `pattern` followed by its sha256 in recipe.yaml.
def recipe-pin [recipe: string, url_pattern: string] {
  # concatenated, not interpolated: the regex groups contain parentheses
  let pattern = ('url: (?<url>' + $url_pattern + ')\s+sha256: (?<sum>[0-9a-f]{64})')
  let hits = ($recipe | parse --regex $pattern)
  if ($hits | is-empty) { error make {msg: $"recipe.yaml has no source matching ($url_pattern)"} }
  $hits | first
}

# Download (cached), sha256-verify and extract a url source into <dest>.
def fetch-source [pin: record, dest: string, cache: string] {
  if ($dest | path exists) { print $"reusing ($dest)"; return }
  mkdir ($cache | path join dl)
  let tarball = ($cache | path join dl ($pin.url | path basename))
  if not ($tarball | path exists) {
    print $"downloading ($pin.url)"
    http get --raw $pin.url | save --force $tarball
  }
  let got = (open --raw $tarball | hash sha256)
  if $got != $pin.sum { error make {msg: $"sha256 mismatch for ($tarball): got ($got), recipe says ($pin.sum)"} }
  ^python ($HERE | path join extract-tar.py) $tarball $dest
}

def main [--src: string = "/tmp/acpp-configure-smoke", --keep-build] {
  if $nu.os-info.name != "linux" or $nu.os-info.arch != "x86_64" {
    error make {msg: "configure-smoke runs on linux-64 only"}
  }
  let prefix = ($env.CONDA_PREFIX? | default "")
  if $prefix == "" { error make {msg: "run inside the smoke environment: pixi run -e smoke configure-smoke"} }
  let repo = ($HERE | path dirname)
  let recipe = (open --raw ($repo | path join recipe.yaml))

  # ---- sources, exactly the recipe's pins -------------------------------
  let llvm = (recipe-pin $recipe 'https://github.com/ROCm/llvm-project/archive/[0-9a-f]{40}\.tar\.gz')
  let ocl_h = (recipe-pin $recipe 'https://github.com/KhronosGroup/OpenCL-Headers/archive/[0-9a-f]{40}\.tar\.gz')
  let ocl_cxx = (recipe-pin $recipe 'https://github.com/KhronosGroup/OpenCL-CLHPP/archive/[0-9a-f]{40}\.tar\.gz')
  let rocm = (recipe-pin $recipe 'https://rocm\.nightlies\.amd\.com/tarball-multi-arch/therock-dist-linux-multiarch-[^\s]+\.tar\.gz')
  let acpp_rev = ($recipe | parse --regex 'acpp_commit: \$\{\{ env\.get\("ACPP_NAGA_SHA", default="(?<sha>[0-9a-f]{40})"\) \}\}' | first | get sha)
  print $"llvm-project ($llvm.url)\nAdaptiveCpp    ($acpp_rev)\nrocm-dist      ($rocm.url)"

  mkdir $src
  fetch-source $llvm ($src | path join llvm-project) $src
  fetch-source $ocl_h ($src | path join OpenCL-Headers) $src
  fetch-source $ocl_cxx ($src | path join OpenCL-CLHPP) $src
  fetch-source $rocm ($src | path join rocm-dist) $src
  let acpp = ($src | path join AdaptiveCpp)
  if not ($acpp | path exists) {
    ^git clone --no-checkout https://github.com/NAGAGroup/AdaptiveCpp.git $acpp
  }
  ^git -C $acpp checkout --quiet $acpp_rev
  let head = (^git -C $acpp rev-parse HEAD | str trim)
  if $head != $acpp_rev { error make {msg: $"AdaptiveCpp is at ($head), the recipe pins ($acpp_rev)"} }

  # ---- the environment the staging build sees (CI log, +CMAKE_ARGS/+CFLAGS...) ----
  let triple = "x86_64-conda-linux-gnu"
  let sysroot = ($prefix | path join $triple sysroot)
  let tools = ($prefix | path join bin)
  let cmake_args = ([
    $"-DCMAKE_AR=($tools)/($triple)-ar"
    $"-DCMAKE_CXX_COMPILER_AR=($tools)/($triple)-gcc-ar"
    $"-DCMAKE_C_COMPILER_AR=($tools)/($triple)-gcc-ar"
    $"-DCMAKE_RANLIB=($tools)/($triple)-ranlib"
    $"-DCMAKE_CXX_COMPILER_RANLIB=($tools)/($triple)-gcc-ranlib"
    $"-DCMAKE_C_COMPILER_RANLIB=($tools)/($triple)-gcc-ranlib"
    $"-DCMAKE_LINKER=($tools)/($triple)-ld"
    $"-DCMAKE_STRIP=($tools)/($triple)-strip"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER"
    "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY"
    "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY"
    $"-DCMAKE_FIND_ROOT_PATH=($prefix);($sysroot)"
    $"-DCMAKE_INSTALL_PREFIX=($prefix)"
    "-DCMAKE_INSTALL_LIBDIR=lib"
    $"-DCMAKE_PROGRAM_PATH=($tools);($tools)"
    "-DCMAKE_POLICY_DEFAULT_CMP0094=NEW"
  ] | str join " ")
  let cflags = $"-march=nocona -mtune=haswell -ftree-vectorize -fPIC -fstack-protector-strong -fno-plt -O2 -ffunction-sections -pipe -fno-merge-constants -isystem ($prefix)/include"
  let ldflags = $"-Wl,-O2 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -Wl,--disable-new-dtags -Wl,--gc-sections -Wl,--allow-shlib-undefined -Wl,-rpath,($prefix)/lib -Wl,-rpath-link,($prefix)/lib -L($prefix)/lib"

  let build = ($src | path join build)
  if (not $keep_build) and ($build | path exists) { rm --recursive --force $build }
  mkdir $build
  let log = ($src | path join configure.log)

  # ---- configure (never build) ------------------------------------------
  let ok = (with-env {
    SRC_DIR: $src
    PREFIX: $prefix
    BUILD_PREFIX: $prefix
    CONDA_BUILD_SYSROOT: $sysroot
    CMAKE_ARGS: $cmake_args
    CFLAGS: $cflags
    CXXFLAGS: $"-fvisibility-inlines-hidden -fmessage-length=0 ($cflags)"
    LDFLAGS: $ldflags
    CMAKE_PREFIX_PATH: $"($build):($env.CMAKE_PREFIX_PATH? | default '')"
  } {
    let args = (stage-args $src $prefix $build)
    $"cmake ($src)/llvm-project/llvm -G Ninja " + ($args | each {|a| $"'($a)'" } | str join " ") + $" -B ($build)"
      | save --force ($src | path join cmake-command.txt)
    try {
      ^cmake ($src | path join llvm-project llvm) -G Ninja ...$args -B $build o+e>| tee { save --force $log }
    } catch {|e| print $"cmake exited with failure: ($e.msg)" }
    (open --raw $log | str contains "Build files have been written to")
  })

  # ---- report -----------------------------------------------------------
  let text = (open --raw $log)
  let blocks = ($text | split row -r '\n\s*\n')
  let errors = ($blocks | where {|b| $b =~ 'CMake Error' })
  let deprec = ($blocks | where {|b| $b =~ '(?i)deprecat' })
  print "\n===== CMake Error blocks ====="
  $errors | each {|b| print $b; print "" } | ignore
  print $"===== blocks mentioning 'deprecat' \(any case\): ($deprec | length) ====="
  $deprec | each {|b| print $b; print "" } | ignore
  # which optional features and which OpenMP the configure ended up with
  print "\n===== feature / OpenMP lines ====="
  $text | lines | where {|l| $l =~ '(?i)(Enable (SWIG|editline|curses|LZMA|Libxml|Python|Tree-sitter)|Python3? |OpenMP|tree-sitter|libxml|LLDB_ENABLE|LLVM_ENABLE_(LIBXML2|LIBEDIT))' } | each {|l| print $l } | ignore
  print $"command: ($src)/cmake-command.txt\nlog:     ($log)"
  if not $ok or ($errors | is-not-empty) {
    error make {msg: "configure FAILED (see the CMake Error blocks above)"}
  }
  print "configure OK"
}
