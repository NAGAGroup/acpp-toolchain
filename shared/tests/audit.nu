# audit.nu — the constraint acceptance suite.
#
#   nu shared/tests/audit.nu [--platform linux-64|win-64] [--channel <url>]
#
# Three kinds of check, because the phase-3 contract is not provable by any one
# of them alone:
#
#   A. SOLVE audits — throwaway pixi workspaces that must lock, or must fail to
#      lock. This is what a consumer's solver actually does.
#   B. ARTIFACT audits — read the metadata out of the built .conda files. A
#      solve can pass for the wrong reason; these assert the exact strings we
#      promised are in the packages.
#   C. EXPORT ROUND TRIP — build a template-shaped consumer whose manifest
#      names `acpp` and NOTHING else, and prove it comes out carrying both the
#      runtime range and the lane range. This is the whole point of the export
#      flip, and it is only observable end to end.
#
# Everything resolves against ./local-channel plus the naga-labs channel unless
# --channel overrides it, so the same suite runs pre-publish (against freshly
# built artifacts) and post-publish (against the channel as consumers see it).

const DEFAULT_CHANNEL = "https://prefix.dev/jackm97/naga-labs"

# ── helpers ────────────────────────────────────────────────────────────────

# Split "clang ==20.1.8" into a pixi manifest line. A bare name means any
# version; anything after the first space is passed through as the spec.
def dep-line [d: string] {
  let parts = ($d | split row " " | where {|x| $x != "" })
  if ($parts | length) == 1 {
    $'($parts | first) = "*"'
  } else {
    $'($parts | first) = "($parts | skip 1 | str join " ")"'
  }
}

# A whole major, as an explicit RANGE. Jack's ruling: "no wildcards. none."
#
# These cases used to say "clang 21.*". That is a version wildcard, and the
# ban is not stylistic — a wildcard's meaning depends on the matcher, so the
# same string can mean different sets to pixi, conda and rattler. A range says
# one thing everywhere, and it is the same form the pin functions emit, so the
# suite asserts specs of the shape our packages actually ship.
def major-range [m: string] {
  let next = (($m | into int) + 1)
  $">=($m),<($next).0a0"
}

def try-solve [platform: string, channels: list<string>, name: string, deps: list<string>, should_solve: bool] {
  let dir = (mktemp -d)
  let dep_lines = ($deps | each {|d| dep-line $d } | str join "\n")
  let chan_lines = ($channels | each {|c| $'"($c)"' } | str join ", ")
  $'[workspace]
name = "audit"
channels = [($chan_lines)]
platforms = ["($platform)"]
# The channel is overlay-first: custom packages win by NAME over conda-forge at
# any version. Declaring the priority explicitly means this audit fails if that
# ever silently changes, instead of quietly testing a different world.
channel-priority = "strict"

[dependencies]
($dep_lines)
' | save ($dir | path join "pixi.toml")
  let res = (do { cd $dir; ^pixi lock --no-progress } | complete)
  let solved = ($res.exit_code == 0)
  let ok = ($solved == $should_solve)
  print $"[(if $ok { 'PASS' } else { 'FAIL' })] solve: ($name) — solved=($solved) expected=($should_solve)"
  if not $ok and $solved == false {
    # Show why, so a genuine regression is not mistaken for the constraint
    # doing its job (they look identical from the exit code alone).
    print ($res.stderr | lines | last 8 | str join "\n")
  }
  rm -rf $dir
  $ok
}

# Pull one metadata file out of a .conda artifact without unpacking it.
def conda-meta [pkg: path, member: string] {
  # The info tarball's name embeds the build string, so it is selected by
  # pattern. Held in a variable rather than written inline: nushell expands
  # bare-word globs for external commands, but not variables.
  let info_glob = "info-*.tar.zst"
  ^unzip -p $pkg $info_glob | ^zstd -d -q -c | ^tar -xO $member | from json
}

def find-pkg [channel_dir: path, subdir: string, name: string] {
  # `glob`, not `ls`: nushell only expands glob patterns written as bare words,
  # so `ls $pattern` would look for a file literally named "acpp-*.conda".
  let hits = (try {
    glob ($channel_dir | path join $subdir $"($name)-*.conda")
  } catch { [] })
  # "acpp-1.0-*" must not match "acpp-tools-1.0-*": require the next path
  # component after the name to be a version, i.e. start with a digit.
  let exact = ($hits | where {|p|
    let rest = ($p | path basename | str substring (($name | str length) + 1)..)
    ($rest | str substring 0..1) =~ '[0-9]'
  })
  if ($exact | is-empty) { null } else { $exact | first }
}

def check [name: string, cond: bool, detail: string] {
  print $"[(if $cond { 'PASS' } else { 'FAIL' })] ($name)($detail)"
  $cond
}

# Does the OTHER lane on the channel already carry the mutex?
#
# The cross-lane MUTEX cases can only bite once both lanes have been rebuilt on
# the phase-3 scheme. In a release run, local-channel holds the new release
# packages while the nightly ones still come from the channel on the old
# scheme, where acpp-llvm does not appear at all — so "nightly compiler +
# release mutex" legitimately solves, and asserting otherwise would be
# asserting that the transition is already finished.
#
# This probes the channel instead of hard-coding a transitional expectation, so
# the case turns itself back on the moment the counterpart lane republishes,
# rather than sitting as a permanently skipped test nobody revisits.
def counterpart-has-mutex [platform: string, pkg: string] {
  let url = $"https://repo.prefix.dev/jackm97/naga-labs/($platform)/repodata.json"
  # --raw + explicit from json: the server's content-type is not always one
  # nushell auto-parses, and a silently-unparsed string would make this probe
  # look like a network failure rather than a parse one.
  let repo = (try { http get --raw $url | from json } catch { null })
  if $repo == null { return null }
  let groups = [($repo | get -o packages | default {}), ($repo | get -o "packages.conda" | default {})]
  let entries = ($groups | each {|g| $g | values } | flatten)
  let mine = ($entries | where {|e| ($e | get -o name) == $pkg })
  if ($mine | is-empty) { return null }
  $mine | any {|e| ($e | get -o depends | default []) | any {|d| $d | str starts-with "acpp-llvm" } }
}

# ── A. solve audits ────────────────────────────────────────────────────────

# NB on the same-major cases: conda-forge's `clang` version tracks the LLVM
# major, so "acpp + clang" no longer proves anything on its own — under the
# phase-3 same-major windows the solver is free to satisfy it with a
# different-major clang. Each direction is therefore pinned explicitly.
def linux-cases [maj: string, next: string] {
  [
    ["suite coherent", [acpp acpp-tools acpp-lldb acpp-runtime-cuda], true]

    # same-major collisions must still be rejected
    ["same-major libllvm rejected", [acpp-runtime $"libllvm($maj)"], false]
    ["same-major clang rejected", [acpp $"clang (major-range $maj)"], false]
    ["same-major lld rejected", [acpp $"lld (major-range $maj)"], false]

    # ...while a DIFFERENT major of the same dev tooling may coexist. This is
    # the concession the same-major windows exist to make.
    ["different-major clang allowed", [acpp $"clang (major-range $next)"], true]
    ["different-major clang-tools allowed", [acpp-runtime $"clang-tools (major-range $next)"], true]
    ["different-major clang-format allowed", [acpp-tools $"clang-format (major-range $next)"], true]

    # lane mixing, both directions, via the mirrored run_constraints
    ["lane mixing rejected (runtime)", [acpp-runtime acpp-runtime-nightly], false]
    ["lane mixing rejected (compiler)", [acpp acpp-nightly], false]
    ["lane mixing rejected (reverse order)", [acpp-nightly acpp], false]

    # ...and independently via the mutex, which is what catches a consumer who
    # pins the wrong lane rather than naming the wrong package
    ["release compiler + nightly mutex rejected", [acpp $"acpp-llvm ==($next)"], false]

    # the taught consumer pin: ==major selects a lane explicitly
    ["mutex ==major selects release lane", [acpp $"acpp-llvm ==($maj)"], true]
    ["mutex ==major selects nightly lane", [acpp-nightly $"acpp-llvm ==($next)"], true]
    ["mutex alone is installable", [$"acpp-llvm ==($maj)"], true]

    # the headline consumer spec from the acceptance criteria
    ["consumer semver range + default lane", ['acpp >=25.10.0,<25.11.0a0'], true]

    ["activation pair", [acpp-clang_linux-64 acpp-clangxx_linux-64], true]
    ["gcc + acpp-clangxx mixed", [gcc_linux-64 acpp-clangxx_linux-64], true]
  ]
}

def win-cases [maj: string, next: string] {
  [
    ["suite coherent", [acpp acpp-tools acpp-runtime-cuda], true]
    # NB these carried "==20.*" until now — a form pixi rejects outright
    # ("expected a version specifier but looks like a matchspec"), so the win
    # cases were failing to parse rather than testing anything. Only the linux
    # half of that bug was caught on run 1; this is the other half.
    ["same-major clang rejected", [acpp $"clang (major-range $maj)"], false]
    ["different-major clang allowed", [acpp $"clang (major-range $next)"], true]
    ["same-major clang-format rejected", [acpp-tools $"clang-format (major-range $maj)"], false]
    ["different-major clang-format allowed", [acpp-tools $"clang-format (major-range $next)"], true]
    ["lane mixing rejected (runtime)", [acpp-runtime acpp-runtime-nightly], false]
    ["lane mixing rejected (compiler)", [acpp acpp-nightly], false]
    ["release compiler + nightly mutex rejected", [acpp $"acpp-llvm ==($next)"], false]
    ["mutex ==major selects release lane", [acpp $"acpp-llvm ==($maj)"], true]
    ["consumer semver range + default lane", ['acpp >=25.10.0,<25.11.0a0'], true]
    ["activation pair", [acpp-clang_win-64 acpp-clangxx_win-64], true]
    # clang-cl activation is an ALTERNATIVE to the clang pair, not an addition
    ["clang-cl activation solo", [acpp-clang-cl_win-64], true]
    ["clang-cl + clang activation conflict", [acpp-clang-cl_win-64 acpp-clang_win-64], false]
  ]
}

# ── B. artifact audits ─────────────────────────────────────────────────────

def artifact-audits [channel_dir: path, subdir: string, maj: string, next: string] {
  mut results = []

  let acpp = (find-pkg $channel_dir $subdir "acpp")
  let rt = (find-pkg $channel_dir $subdir "acpp-runtime")
  let mutex = (find-pkg $channel_dir "noarch" "acpp-llvm")

  if $acpp == null or $rt == null or $mutex == null {
    print $"[FAIL] artifact audits: missing artifacts — acpp=($acpp) runtime=($rt) mutex=($mutex)"
    return [false]
  }

  # The mutex version must be the BARE major. A dotted version here silently
  # breaks every "acpp-llvm ==20" pin consumers were taught to write, and it
  # would not fail any solve — hence a direct assert. Also enforced at publish.
  let mv = (conda-meta $mutex "info/index.json" | get version)
  $results = ($results | append (check "mutex version is a bare major" ($mv =~ '^[0-9]+$') $" — version=($mv)"))

  # The mutex must carry no payload: it is a name to collide on, nothing more.
  # (It is also what makes it safe as a host dep of a staging-inheriting
  # output, since rattler-build ejects any path a host dep provides.)
  let mdep = (conda-meta $mutex "info/index.json" | get depends)
  $results = ($results | append (check "mutex has no dependencies" (($mdep | length) == 0) $" — depends=($mdep)"))

  # acpp's STRONG run_exports are the contract every consumer inherits.
  let ex = (conda-meta $acpp "info/run_exports.json")
  let strong = ($ex | get -o strong | default [])
  let has_rt = ($strong | any {|s| $s =~ '^acpp-runtime >=' and $s =~ ',<' })
  let has_mutex = ($strong | any {|s| $s == $"acpp-llvm >=($maj),<($next).0a0" })
  $results = ($results | append (check "acpp exports the runtime as a RANGE" $has_rt $" — strong=($strong)"))
  $results = ($results | append (check "acpp exports the lane mutex" $has_mutex $" — strong=($strong)"))
  # An exact pin here would defeat the flip: it is the nightly lane's idiom.
  $results = ($results | append (check "acpp exports no exact pin" (not ($strong | any {|s| $s =~ '==' })) $" — strong=($strong)"))

  # The runtime must depend on its own lane, or nothing ties the shipped
  # libraries to the major they were built from.
  let rtdep = (conda-meta $rt "info/index.json" | get depends)
  let rt_mutex = ($rtdep | any {|s| $s == $"acpp-llvm >=($maj),<($next).0a0" })
  $results = ($results | append (check "acpp-runtime depends on its lane mutex" $rt_mutex $" — depends=($rtdep)"))

  # Build strings must name the lane; that is where it lives now that the
  # version is pure.
  let bs = (conda-meta $acpp "info/index.json" | get build)
  $results = ($results | append (check "build string carries the lane tag" ($bs | str starts-with "llvm") $" — build=($bs)"))

  # ...and the version must NOT.
  let av = (conda-meta $acpp "info/index.json" | get version)
  $results = ($results | append (check "version is free of the lane tag" (not ($av | str contains "llvm")) $" — version=($av)"))

  $results
}

# ── C. export round trip ───────────────────────────────────────────────────
#
# The acceptance criterion in words: "a template-shaped consumer receives BOTH
# the runtime range and the mutex range with zero manifest text". This builds
# exactly that consumer — its requirements name `acpp` and nothing else — and
# asserts what lands in its depends.

def export-round-trip [channel_dir: path, maj: string, next: string] {
  let dir = (mktemp -d)
  let recipe = ($dir | path join "recipe.yaml")
  'package:
  name: audit-consumer
  version: "0.0.1"

build:
  number: 0

requirements:
  # ZERO manifest text about runtimes or lanes. Everything this package ends
  # up depending on must arrive through run_exports.
  build:
    - acpp
' | save --force $recipe

  let chan = (file-url $channel_dir)
  let res = (do {
    ^rattler-build build --recipe $recipe --channel $chan --channel $DEFAULT_CHANNEL --output-dir ($dir | path join "out") --no-test
  } | complete)

  if $res.exit_code != 0 {
    print "[FAIL] export round trip: consumer build failed"
    print ($res.stderr | lines | last 15 | str join "\n")
    rm -rf $dir
    return [false]
  }

  let built = (find-pkg ($dir | path join "out") (if $nu.os-info.name == "windows" { "win-64" } else { "linux-64" }) "audit-consumer")
  if $built == null {
    print "[FAIL] export round trip: no consumer artifact produced"
    rm -rf $dir
    return [false]
  }
  let deps = (conda-meta $built "info/index.json" | get depends)
  rm -rf $dir

  mut results = []
  $results = ($results | append (check "consumer inherits the runtime RANGE"
    ($deps | any {|d| $d =~ '^acpp-runtime >=' and $d =~ ',<' and not ($d =~ '==') })
    $" — depends=($deps)"))
  $results = ($results | append (check "consumer inherits the lane mutex"
    ($deps | any {|d| $d == $"acpp-llvm >=($maj),<($next).0a0" })
    $" — depends=($deps)"))
  $results
}

def file-url [p: path] {
  let abs = ($p | path expand | str replace --all '\' '/')
  $"file:///($abs | str trim --left --char '/')"
}

# ── main ───────────────────────────────────────────────────────────────────

def main [
  --platform: string = "linux-64"
  --channel: string = ""            # extra channel; defaults to naga-labs
  --skip-round-trip                 # the round trip installs the toolchain
] {
  let remote = (if $channel == "" { $DEFAULT_CHANNEL } else { $channel })
  let channel_dir = "local-channel"
  let channels = [(file-url $channel_dir) $remote]

  # Read the majors out of the artifacts rather than hard-coding them, so an
  # LLVM bump does not quietly leave this suite asserting last year's contract.
  let mutex_pkgs = (try { glob ($channel_dir | path join "noarch" "acpp-llvm-*.conda") } catch { [] })
  if ($mutex_pkgs | is-empty) {
    error make {msg: "audit: no acpp-llvm mutex artifact in local-channel/noarch — the lane build must ship it"}
  }
  let majors = ($mutex_pkgs | each {|p| conda-meta $p "info/index.json" | get version } | sort)
  let maj = (if $platform == "win-64" { $majors | first } else { $majors | first })
  let next = ($majors | last)
  if $maj == $next {
    print $"NOTE: only one mutex major present \(($maj)\); cross-major cases will be vacuous"
  }
  print $"auditing platform=($platform) release-major=($maj) other-major=($next)"

  let cases = (if $platform == "win-64" { win-cases $maj $next } else { linux-cases $maj $next })
  mut results = []
  for c in $cases {
    $results = ($results | append (try-solve $platform $channels $c.0 $c.1 $c.2))
  }

  # The reverse mutex direction, gated on the counterpart lane actually having
  # been rebuilt on this scheme. See counterpart-has-mutex.
  let cp = (counterpart-has-mutex $platform "acpp-nightly")
  if $cp == true {
    $results = ($results | append (try-solve $platform $channels
      "nightly compiler + release mutex rejected" [acpp-nightly $"acpp-llvm ==($maj)"] false))
  } else {
    print $"[SKIP] solve: nightly compiler + release mutex rejected — the nightly lane on the channel does not carry the mutex yet \(probe=($cp)\); this case arms itself once nightly republishes on the phase-3 scheme"
  }

  $results = ($results | append (artifact-audits $channel_dir $platform $maj $next))

  if not $skip_round_trip {
    $results = ($results | append (export-round-trip $channel_dir $maj $next))
  }

  let failed = ($results | where {|r| not $r } | length)
  if $failed == 0 {
    print $"ALL AUDITS PASS \(($results | length) checks\)"
  } else {
    error make {msg: $"($failed) of ($results | length) audit checks FAILED"}
  }
}
