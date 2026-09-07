# build-platform.nu — build and publish every package of ONE platform into a
# local channel, in dependency order, in ONE process.
#
# ⚠ SUPERSEDED, AND NOT YET REWRITTEN. Two of its premises died with the E2E
# lift and are left below only because the reasoning is worth reading:
#
#   * THE `--path` LOOP. It existed because a whole-workspace publish refused
#     the set. It does not any more — the whole-workspace form is what renders
#     and publishes this tree today, and it is the only form that tolerates a
#     source sibling named in run_exports.
#   * THE HARDCODED `ORDER`. The set is now ~45 packages, not fourteen, and
#     pixi computes the build order itself from the workspace dependency graph.
#     The list here is a fossil; its set-agreement guard would fail on the
#     first run, which is the correct behaviour for a stale list and the reason
#     this file cannot silently do the wrong thing in the meantime.
#
# What survives the rewrite is the ONE-JOB-PER-PLATFORM rule below, the
# set-agreement guard and the artifact collection. Step E2E-4 writes the real
# thing (staging.yml, each platform independently dispatchable).
#
# WHY ONE JOB PER PLATFORM. The expensive _acpp-stage build is reused across
# every carving package through pixi's .pixi/bld cache, and that cache does
# not cross runners. Parallelise by PLATFORM, never by package: a job per
# package would rebuild LLVM per package.
#
# WHY `--path` PER PACKAGE. A whole-workspace `pixi publish` refuses the set,
# because _acpp-stage is publish = false and "every source dependency of a
# published package must itself be published in the same batch". A `--path`
# publish is a batch of one, where only RUN dependencies may not be source
# dependencies — build and host source deps are fine, and the stage is a host
# dep.
#
# WHY ORDER MATTERS. `acpp`'s recipe carries `acpp-runtime ==<version>` as a
# HOST dependency, and host dependencies resolve. acpp-runtime cannot be a
# workspace sibling of acpp (pixi would then classify it as a source RUN
# dependency, because acpp names it in run_exports, and refuse to publish acpp
# alone), so it has to reach acpp through a channel — which means it must
# already be published when acpp builds.

# Dependency order, not alphabetical. acpp-runtime leads because `acpp`
# consumes it from the channel; anything downstream of `acpp` follows it.
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

const ORDER = [
  "acpp-runtime"
  "acpp-runtime-cuda"
  "acpp-runtime-level-zero"
  "acpp-runtime-ocl"
  "acpp-runtime-rocm"
  "acpp"
  "acpp-compiler-rt"
  "acpp-lldb"
  "acpp-llvm-spirv"
  "acpp-activation-linux"
  "acpp-activation-win"
  "acpp-activation-osx"
]

def main [
  --channel: string                # target channel: a URL, or a local path
  --packages-dir: string = "packages"
  --artifacts-dir: string = "dist" # where the gate will look afterwards
  --build-dir: string = ".pixi/bld"
] {
  if ($channel | is-empty) {
    error make {msg: "build-platform: --channel is required"}
  }
  # A package added to the tree but absent from ORDER would be silently
  # skipped, and the first sign would be a package missing from the channel.
  # Detect packages BY MANIFEST, not by name: packages/acpp-core holds NOTES
  # and lifts/*/PINNED_REF and is not a package despite being named like one.
  let on_disk = (
    ls $packages_dir
    | where type == dir
    | get name
    | where {|p| ($p | path join "pixi.toml" | path exists) }
    | each {|p| $p | path basename }
    | where {|n| $n != "_acpp-stage" }   # built as a dependency, never published
    | sort
  )
  let missing = ($on_disk | where {|n| $n not-in $ORDER })
  let extra = ($ORDER | where {|n| $n not-in $on_disk })
  if ($missing | is-not-empty) {
    error make {msg: $"build-platform: packages on disk but not in ORDER, so they would be silently skipped: ($missing | str join ', ')"}
  }
  if ($extra | is-not-empty) {
    error make {msg: $"build-platform: ORDER names packages that do not exist: ($extra | str join ', ')"}
  }

  mut built = []
  mut skipped = []
  for name in $ORDER {
    let dir = ($packages_dir | path join $name)
    print $"── ($name) ──"
    let r = (^pixi publish --path $dir --to $channel --force --no-progress | complete)
    let out = ($r.stdout + $r.stderr)

    if $r.exit_code == 0 {
      $built = ($built | append $name)
      continue
    }

    # A package whose recipe skips on THIS platform also exits non-zero.
    # MEASURED: `no package produces outputs for platform <subdir>`. Treating
    # that as a failure would kill the whole win or osx leg on the first
    # legitimately-skipped package. Matched narrowly and counted, never
    # swallowed.
    #
    # NOTE this does NOT catch a recipe that fails to RENDER on a platform it
    # means to skip — a variant key is resolved before `skip:` is honoured, so
    # an unguarded reference to a key scoped away from that platform produces a
    # template error, not this message. That is a recipe defect and it SHOULD
    # fail here loudly.
    if ($out | str contains "no package produces outputs for platform") {
      print $"   skipped: no outputs for this platform"
      $skipped = ($skipped | append $name)
      continue
    }

    # VERDICT FIRST, then the detail. MEASURED: the captured pixi output is
    # carriage-return heavy (progress rendering), so ANYTHING printed after it
    # is overwritten on the same line and never reaches the log — including
    # the `error make` message. The job still aborts with a non-zero exit, but
    # with nothing naming the package that failed. Printing the verdict before
    # the dump is what makes a CI failure legible.
    # VERDICT FIRST, then the detail, and NO bare parens in the interpolation.
    # `$"... (exit $x) ..."` does not print "(exit 1)" — nushell evaluates the
    # parenthesised expression, so it CALLS exit and terminates the script
    # then and there. The job aborted with a plausible non-zero code and no
    # diagnostics at all, which read as correct behaviour.
    print $"build-platform: FAILED on ($name) — pixi exit ($r.exit_code), output follows"
    print $out
    error make {msg: $"build-platform: ($name) failed, pixi exit ($r.exit_code)"}
  }

  # Report both counts. Silence is not a result: a reader must be able to see
  # that every package was accounted for, and that the skips are the ones this
  # platform expects rather than a recipe skipping by accident.
  print ""
  print $"build-platform: published (($built | length)), skipped (($skipped | length)), of (($ORDER | length)) packages"
  if ($skipped | is-not-empty) {
    print $"  skipped here: ($skipped | str join ', ')"
  }
  let accounted = (($built | length) + ($skipped | length))
  if $accounted != ($ORDER | length) {
    error make {msg: $"build-platform: (($ORDER | length)) packages expected, only ($accounted) accounted for"}
  }
  if ($built | is-empty) {
    error make {msg: "build-platform: nothing was published — every package skipped, which is never correct"}
  }

  # Collect the artifacts the gates run against.
  #
  # ONLY the packages we published. `_acpp-stage` also leaves a .conda under
  # the build dir, and it contains EVERYTHING the carving packages ship — so
  # including it would make the disjointness gate report an overlap against
  # every single package, by design rather than by defect. Collect by name
  # from the built list, never by globbing the build directory.
  mut collected = 0
  for name in $built {
    let found = (glob-native $"($build_dir)/($name)/*/output/*/*.conda")
    if ($found | is-empty) {
      error make {msg: $"build-platform: ($name) published but no artifact found under ($build_dir)/($name)"}
    }
    for a in $found {
      # Keep the platform subdir the artifact was built into: the gate treats
      # each subdirectory as one platform and compares within it.
      let subdir = ($a | path dirname | path basename)
      let dest = ($artifacts_dir | path join $subdir)
      mkdir $dest
      cp -P $a ($dest | path join ($a | path basename))
      $collected = $collected + 1
    }
  }
  print $"build-platform: collected ($collected) artifact\(s\) into ($artifacts_dir)/ for gating"
  if $collected < ($built | length) {
    error make {msg: $"build-platform: (($built | length)) packages published but only ($collected) artifacts collected"}
  }
}