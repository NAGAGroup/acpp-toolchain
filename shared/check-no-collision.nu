# C-11 publish gate: never publish a package name that already exists on
# conda-forge.
#
# WHY THIS IS INCIDENT-GRADE, NOT HYGIENE: the naga-labs channel layers
# conda-forge server-side and is configured OVERLAY-FIRST, so the merge is a
# NAMESPACE merge, not a version race — a colliding name published here wins
# over conda-forge at ANY version, for EVERY consumer of the channel. A stale
# or lower-versioned upload silently replaces the conda-forge package in
# consumer solves (live example: a teaching-wrapper fmt 11.2.0 shadowed
# conda-forge fmt 12.2.0 channel-wide, 2026-08-09).
#
# Mechanism (ratified C-11, 2026-08-09 acpp-branch lockdown): every package
# name about to be uploaded is checked against the conda-forge
# feedstock-outputs registry — outputs/<a>/<b>/<c>/<name>.json must 404.
# Names are taken from the ACTUAL .conda artifacts staged for upload, never
# from recipe sources, so the gate cannot drift from what ships.
#
# Fail-closed: any probe result other than a clean 404 (including transient
# network errors) fails the gate.

# Names deliberately allowed to shadow conda-forge. Must stay empty short of
# an explicit Jack ruling recorded in the design doc.
const ALLOWLIST: list<string> = []

def probe-conda-forge [name: string]: nothing -> int {
    if ($name | str length) < 3 {
        error make { msg: $"name '($name)' too short for feedstock-outputs sharding; extend the script before publishing it" }
    }
    let a = ($name | str substring 0..0)
    let b = ($name | str substring 1..1)
    let c = ($name | str substring 2..2)
    let url = $"https://raw.githubusercontent.com/conda-forge/feedstock-outputs/main/outputs/($a)/($b)/($c)/($name).json"
    http get --full --allow-errors $url | get status
}

def main [channel_dir: string = "local-channel"] {
    let artifacts = (glob $"($channel_dir)/**/*.conda") ++ (glob $"($channel_dir)/**/*.tar.bz2")
    if ($artifacts | is-empty) {
        error make { msg: $"no conda artifacts found under '($channel_dir)' — nothing staged for upload, refusing to pass vacuously" }
    }

    # <name>-<version>-<build>.conda → name (version/build cannot contain '-')
    let names = ($artifacts
        | each {|p| $p | path basename | str replace --regex '\.(conda|tar\.bz2)$' '' | split row '-' | drop 2 | str join '-' }
        | uniq | sort)

    print $"C-11 gate: checking ($names | length) package name\(s\) against conda-forge feedstock-outputs"

    let collisions = ($names | each {|name|
        let status = (probe-conda-forge $name)
        if $status == 404 {
            print $"  clean: ($name)"
            null
        } else if $status == 200 {
            if $name in $ALLOWLIST {
                print $"  ALLOWLISTED shadow: ($name) \(exists on conda-forge; explicitly ruled\)"
                null
            } else {
                print $"  COLLISION: ($name) exists on conda-forge"
                $name
            }
        } else {
            error make { msg: $"probe for '($name)' returned HTTP ($status) — cannot verify, failing closed" }
        }
    } | compact)

    if not ($collisions | is-empty) {
        error make { msg: ($"C-11 VIOLATION: refusing to publish name\(s\) that exist on conda-forge: (($collisions | str join ', ')). "
            + "naga-labs layers conda-forge OVERLAY-FIRST: the merge is by NAME, not version — our upload would win at any version "
            + "and silently replace the conda-forge package for every consumer of the channel. Rename the output \(e.g. '-acpp' suffix\) "
            + "or obtain an explicit ruling before allowlisting.") }
    }

    print "C-11 gate: PASS — no conda-forge collisions in the staged upload set"
}
