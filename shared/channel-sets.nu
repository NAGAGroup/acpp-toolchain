#!/usr/bin/env nu
# Shared view of the published channel, in terms of nightly BUILD-SETS.
#
# This module exists so that the two pieces of code with an opinion about what
# a "set" is — the pruner that DELETES sets, and the keeper recorder that
# PROTECTS them — cannot disagree. A second `set-id` implementation that drifted
# from the pruner's would mean the thing we recorded as kept and the thing we
# refuse to delete are different strings, and the failure would be silent until
# a keeper stopped protecting anything. There is therefore exactly one
# definition, here, and both callers `use` it.
#
# Nothing in this module writes anywhere. Reading the channel is all it does.

export const CHANNEL = "jackm97/naga-labs"
export const MUTEX_NAME = "acpp-llvm"
export const KEEPERS_FILE = "nightly/keepers.txt"
export const PLATFORMS = ["linux-64" "win-64" "noarch"]

# The platforms a set must be complete on before it counts as a set at all.
# `noarch` is deliberately absent: it carries only the lane mutex, which is
# shared by both lanes and belongs to no dated set.
export const SET_PLATFORMS = ["linux-64" "win-64"]

export def repodata [platform: string] {
  let url = $"https://repo.prefix.dev/($CHANNEL)/($platform)/repodata.json"
  try { http get --raw $url | from json } catch { null }
}

# Every artifact on the channel, flattened, tagged with its subdir.
export def channel-artifacts [] {
  $PLATFORMS | each {|p|
    let repo = (repodata $p)
    if $repo == null { return [] }
    let groups = [($repo | get -o packages | default {}), ($repo | get -o "packages.conda" | default {})]
    $groups | each {|g|
      $g | transpose fname meta | each {|e| {
        platform: $p,
        fname: $e.fname,
        name: ($e.meta | get -o name),
        version: ($e.meta | get -o version),
        build: ($e.meta | get -o build)
      }}
    } | flatten
  } | flatten
}

# The nightly-lane subset. The mutex is excluded BY NAME before anything else
# looks at it: it is shared by both lanes, has no date in its version, and
# every published lane artifact depends on it.
export def nightly-artifacts [] {
  channel-artifacts | where {|a|
    ($a.name != $MUTEX_NAME) and ($a.name | str contains "-nightly")
  }
}

# Read keepers, ignoring comments and blank lines. Re-read every run.
#
# Takes the path rather than closing over the constant so that a caller which
# was given a different keepers file READS the same file it WRITES. Defaulting
# the parameter keeps every existing call site unchanged.
export def read-keepers [file: string = $KEEPERS_FILE] {
  if not ($file | path exists) { return [] }
  open --raw $file
  | lines
  | each {|l| $l | split row '#' | first | str trim }
  | where {|l| $l != "" }
}

# The set id is "<date>_llvm<version>" — the SAME string a keeper line uses, so
# the two can be compared directly and a keeper can never silently fail to
# match the thing it is meant to protect.
#
# It has to be derived from two different layouts, because the channel holds
# both during the cutover:
#
#   old scheme: version = "2026.08.09_llvm21.1.8", build = "h4ea4446_9"
#   new scheme: version = "2026.08.09",            build = "llvm21_1_8_h62b9992_6"
#
# NB the unit is (date, llvm_version) and deliberately spans ALL build numbers
# of that date: retention is "newest N DATED sets", and the keeper format names
# no build number. Earlier this function derived the tag by splitting the build
# string unconditionally, which on old-scheme artifacts left the whole build
# string in the id — every individual build became its own "set" (46 of them
# against a channel holding two dates), which would have pruned partial sets.
export def set-id [a: record] {
  if ($a.version | str contains "_llvm") {
    # Old scheme: the version IS the set id.
    $a.version
  } else {
    let tag = ($a.build | split row '_h' | first)      # "llvm21_1_8"
    if ($tag | str starts-with "llvm") {
      $"($a.version)_($tag | str replace --all '_' '.')"   # -> "2026.08.09_llvm21.1.8"
    } else {
      # No lane tag anywhere: refuse to guess. Such an artifact is grouped
      # under an id that matches no keeper and no window, and the caller
      # treats unknown sets as ineligible for deletion.
      $"($a.version)_UNKNOWN"
    }
  }
}

# The calendar month a set id belongs to, as the "YYYY.MM" prefix of its date.
# Keeper policy is per-month, so this is the comparison key for "does this
# month already have a keeper".
export def set-month [id: string] {
  $id | split row '_' | first | split row '.' | first 2 | str join '.'
}
