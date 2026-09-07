# check-superset.nu — assert that we ship at least the acpp analogue of every
# upstream output in the ratified subset, on the platform being checked.
#
# THE SUPERSET RULE, and why it is a script rather than a habit: our shipped
# set must contain the acpp analogue of every conda-forge LLVM output we agreed
# to carry. We may add more (acpp-bolt, the backend metapackages) and never
# fewer. Jack's justification is the one that matters — matching upstream
# REMOVES DECISIONS, and every decision is a chance to be wrong — so the rule
# has to be checkable or it is merely something we remember.
#
# THE TARGET LIST IS DERIVED, THEN COMMITTED. `--regenerate` reads the
# reference monolith's GENERATED recipe/outputs.json (itself produced by
# rattler-build --render-only over that recipe, so it is upstream's own answer
# and not a transcription), applies the ratified exclusions, maps each
# surviving name to its acpp form, and writes packaging/upstream-subset.json.
# The check then reads that file. Regenerating is a deliberate act with a diff;
# the daily gate never reaches for the monolith.
#
# IT ASSERTS THE COUNT IT EXAMINED. "No gaps" over an empty target list is not
# a result — it is the vacuous pass that makes a gate worthless. The committed
# file records how many names each platform expects, and a run that examines
# fewer fails before it can report success.
#
#   pixi run -e packaging nu tools/check-superset.nu --platform linux-64
#   pixi run -e packaging nu tools/check-superset.nu --regenerate

const MONOLITH = "/home/jack/projects/llvm-feedstocks-monolith/recipe/outputs.json"
const TARGET_FILE = "packaging/upstream-subset.json"
const PLATFORMS = ["linux-64" "win-64" "osx-arm64"]

# ---------------------------------------------------------------------------
# THE RATIFIED EXCLUSIONS — Jack's, one predicate per ruling so a reader can
# see which line implements which decision.
# ---------------------------------------------------------------------------
def excluded [name: string, platform: string] {
  # The GCC activation family. "We're not building gcc, we don't need to
  # reference its activations" — only libstdc++/libgcc DEVEL packages get
  # installed alongside, as conda-forge dependencies.
  if (($name | str starts-with "gcc_") or ($name | str starts-with "gxx_") or ($name | str starts-with "gfortran_") or ($name | str starts-with "gcc_bootstrap_")) { return true }
  # Everything cross. A name ending in _<some platform> belongs to the platform
  # it names; upstream renders the whole eight-target matrix, we build three
  # platforms NATIVELY. Keep only the ones naming the platform being checked.
  let plat_suffixed = ($name | parse -r '_(?P<p>(linux|osx|win)-[a-z0-9_]+)$' | get p.0?)
  if $plat_suffixed != null and $plat_suffixed != $platform { return true }
  # clang_bootstrap_* is a repackaging of the compiler for bootstrapping, which
  # acpp already is.
  if ($name | str starts-with "clang_bootstrap_") { return true }
  # The Windows SDK and MSVC headers exist to feed the cross-from-linux path,
  # which we do not use; both are `skip: win` upstream.
  if $name in ["winsdk" "msvc-headers-libs"] { return true }
  # polly: conda-forge abandoned the feedstock (six commits ending 2023-10-03,
  # no llvm-21 build at all). lit and python-clang: not part of a compiler
  # toolchain a SYCL developer uses.
  if $name in ["polly" "lit" "python-clang"] { return true }
  # libcxx is osx-only for us: on linux and win acpp's runtime uses the
  # platform's native libstdc++/MSVC stdlib, and anyone needing libc++ there is
  # not building an acpp application.
  if ($name | str starts-with "libcxx") and $platform != "osx-arm64" { return true }
  # libcxxabi does not exist for us on ANY platform: upstream skips it off
  # linux, its own libcxx-devel test asserts lib/libc++abi.dylib is ABSENT on
  # osx ("this breaks exception passing"), and conda-forge publishes no
  # libcxxabi for osx-arm64 at all.
  if $name == "libcxxabi" { return true }
  # An alternative to the clang/clangxx activation pair rather than an addition
  # to it — it excludes them by run_constraint. We build and publish it; it is
  # simply not part of the set a single environment holds.
  false
}

# ---------------------------------------------------------------------------
# THE NAME MAPPING. Upstream's tree is at ITS head version, 23.1.0; we lift the
# PATTERN and substitute our major. TWO substitutions are needed, not one:
# ---------------------------------------------------------------------------
def to_acpp [name: string] {
  # 1. The LLVM major, 23 -> 21. Anchored so it only fires where 23 IS the
  #    version: at the end of the name, or before a `.` or `_`. This is what
  #    keeps `libclang13` intact — 13 is libclang's SOVERSION, which upstream's
  #    own cbc says stopped tracking the major at LLVM 14, and it is not a
  #    number we substitute.
  # 2. The SPIR-V translator, 22 -> 21. Upstream versions llvm-spirv on the
  #    KHRONOS release (22.1.2 for LLVM 22), and our source is a branch head of
  #    AdaptiveCpp's fork with no tag at all — so we version it on the LLVM it
  #    belongs to. That ruling is why `acpp-llvm-spirv-21` and
  #    `acpp-libllvmspirv21` are the correct names here.
  let mapped = ($name
    | str replace -r '23($|[._])' '21$1'
    | str replace -r '^(llvm-spirv-|libllvmspirv)22$' '${1}21')
  $"acpp-($mapped)"
}

def build_targets [] {
  if not ($MONOLITH | path exists) {
    error make {msg: $"check-superset: the reference monolith is not at ($MONOLITH) — regeneration needs it; the committed target list does not"}
  }
  let j = (open $MONOLITH)
  mut out = {}
  for p in $PLATFORMS {
    let upstream = ($j.output_names_by_platform | get $p)
    let kept = ($upstream | where {|n| not (excluded $n $p) } | each {|n| to_acpp $n } | uniq | sort)
    $out = ($out | insert $p $kept)
  }
  $out
}

# The publish set. From a SAVED LOG when one is given — in CI the real publish
# has already printed the set, and that log is what was actually uploaded,
# which is stronger evidence than a fresh render as well as minutes cheaper.
# Otherwise from the dry run, which is the same instrument.
def shipped_names [platform: string, log: string] {
  let text = (if ($log | is-empty) {
    let r = (^pixi publish --dry-run --target-platform $platform --to ./local-channel | complete)
    if $r.exit_code != 0 {
      print $r.stderr
      error make {msg: $"check-superset: the dry run for ($platform) failed"}
    }
    $r.stderr
  } else {
    if not ($log | path exists) { error make {msg: $"check-superset: ($log) does not exist"} }
    open --raw $log
  })
  let names = ($text | lines
    | each {|l| $l | parse -r '^\s*- (?P<n>\S+) v\S+ \[' | get n.0? } | compact | uniq)
  if ($names | is-empty) {
    error make {msg: $"check-superset: parsed zero package names for ($platform) — a comparison against nothing is not a pass"}
  }
  $names
}

def main [--platform: string, --regenerate, --log: string, --targets-file: string = $TARGET_FILE] {
  if $regenerate {
    let targets = (build_targets)
    let payload = {
      generated_by: "tools/check-superset.nu --regenerate",
      source: $MONOLITH,
      note: "Upstream's own output names, per platform, minus the ratified exclusions, mapped to our acpp- names. Regenerate deliberately and read the diff; the gate reads this file, never the monolith.",
      counts: ($PLATFORMS | reduce --fold {} {|p, acc| $acc | insert $p (($targets | get $p) | length) }),
      names: $targets,
    }
    mkdir ($TARGET_FILE | path dirname)
    $payload | to json --indent 2 | save -f $TARGET_FILE
    for p in $PLATFORMS { print $"($p): ($targets | get $p | length) target names" }
    print $"check-superset: wrote ($TARGET_FILE)"
    return
  }

  if ($platform | is-empty) {
    error make {msg: "check-superset: --platform <p> is required (or --regenerate)"}
  }
  if not ($targets_file | path exists) {
    error make {msg: $"check-superset: ($targets_file) is missing — run with --regenerate"}
  }
  let doc = (open $targets_file)
  let targets = ($doc.names | get $platform)
  let expected = ($doc.counts | get $platform)

  # THE ANTI-VACUITY GUARD. A target list that shrank — a bad filter, a
  # truncated file, a platform key that does not exist — must fail here rather
  # than sail through as "no gaps found".
  if ($targets | length) != $expected {
    error make {msg: $"check-superset: target list for ($platform) holds ($targets | length) names but the file records ($expected) — the list is inconsistent with its own count"}
  }
  if ($targets | length) < 20 {
    error make {msg: $"check-superset: only ($targets | length) target names for ($platform); the ratified subset is far larger, so this is a broken filter rather than a pass"}
  }

  let shipped = (shipped_names $platform $log)
  let missing = ($targets | where {|t| $t not-in $shipped })
  print $"check-superset: ($platform) — examined ($targets | length) upstream names against ($shipped | length) shipped packages"
  if not ($missing | is-empty) {
    for m in $missing { print $"MISSING ($m)" }
    error make {msg: $"check-superset: ($missing | length) upstream output\(s\) have no acpp counterpart on ($platform)"}
  }
  let extra = ($shipped | where {|s| $s not-in $targets })
  print $"check-superset: ours beyond upstream on ($platform) \(allowed, the rule is a floor\): ($extra | str join ', ')"
  print $"check-superset: OK — ($platform) ships all ($targets | length) required names"
}
