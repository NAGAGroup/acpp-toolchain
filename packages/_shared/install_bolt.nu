# install_bolt.nu — acpp-bolt's slice of the stage.
#
# BOLT IS THE ONE PACKAGE WITH NO UPSTREAM ARTIFACT TO SCOPE AGAINST.
# conda-forge packages no BOLT at all: measured with tools/upstream-paths.nu
# against llvm-tools, llvmdev and clang-tools at 21.1.8, none of which carries
# a single bolt binary. There is no feedstock, no output and no glob to lift.
#
# So the scope comes from the only other evidence available — our own `main`,
# where these four binaries have been built and shipped inside acpp-tools since
# the toolchain existed, and are asserted by that package's own
# package_contents test. That is a weaker source than a published artifact and
# it is named as such rather than dressed up: the REQUIRED list is what main
# proved exists, and everything else BOLT's install can produce is OPTIONAL and
# logged, the same shape install_openmp.nu uses for the paths our union stage
# may or may not build.
#
# LINUX ONLY, and that is a property of the stage: BOLT is ELF-only with no
# darwin port, and build-stage.nu puts it in LLVM_ENABLE_PROJECTS on the linux
# leg alone. The recipe expresses that as a skip, so this script never runs
# elsewhere.

def slashes [] { str replace --all '\' '/' }

def place [src: string, layout_root: string, stage: string] {
  let rel = ($src | slashes | path relative-to ($stage | slashes))
  let dst = ($layout_root | path join $rel)
  mkdir ($dst | path dirname)
  cp -P $src $dst
}

def main [] {
  let layout_root = $env.PREFIX
  let stage = ($layout_root | path join "_stage" | slashes)
  if not ($stage | path exists) {
    error make {msg: $"install_bolt: stage directory ($stage) does not exist — is _acpp-stage a host dependency of this package?"}
  }

  # REQUIRED — the four programs main ships and asserts. A missing one means
  # the stage stopped building BOLT, which must fail the build rather than
  # quietly produce a smaller package.
  let required = ["bin/llvm-bolt" "bin/llvm-bolt-heatmap" "bin/perf2bolt" "bin/merge-fdata"]

  # OPTIONAL — the rest of what BOLT's install target can emit. llvm-boltdiff
  # and llvm-bolt-binary-analysis are separate tools in the bolt tree; the two
  # runtime archives are what `llvm-bolt -instrument` links into an
  # instrumented binary, so shipping the tool without them would be half a
  # package — but whether our union build installs them is exactly the thing no
  # render can answer. They are listed, and the build LOGS which were absent.
  # That log line is what this list gets tightened against on the first real
  # linux build.
  let optional = ["bin/llvm-boltdiff" "bin/llvm-bolt-binary-analysis"
                  "lib/libbolt_rt_instr.a" "lib/libbolt_rt_hugify.a"
                  "lib/libbolt_rt_instr_osx.a"]

  mut placed = 0
  for rel in $required {
    let src = ($stage | path join $rel)
    if not ($src | path exists) {
      error make {msg: $"install_bolt: ($rel) is a required part of this package and is not in the stage at ($src) — the slice has rotted against the stage"}
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

  if ($missing | is-empty) {
    print "install_bolt: every optional path was present"
  } else {
    print $"install_bolt: optional paths ABSENT from this stage, tighten this list against them: ($missing | str join ', ')"
  }
  print $"install_bolt: placed ($placed) files"
}
