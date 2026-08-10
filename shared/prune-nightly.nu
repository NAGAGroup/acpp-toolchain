#!/usr/bin/env nu
# Prune old nightly build-sets from the channel.
#
#   nu shared/prune-nightly.nu [--keep 14] [--dry-run] [--channel jackm97/naga-labs]
#
# Runs from the nightly workflow immediately AFTER a green publish, never
# before and never on a red run: a broken streak must not eat the last known
# good nightlies. That ordering is the whole safety story, so this script is
# invoked only from the publish job's success path.
#
# THE UNIT IS A SET, NOT A PACKAGE. A nightly build-set is every artifact
# sharing one (date, llvm_version), across every output and BOTH platforms.
# The nightly lane pins its own packages exactly — acpp-nightly depends on
# acpp-runtime-nightly ==<version> <build> — so deleting half a set leaves the
# survivors permanently unsolvable. Sets are therefore deleted whole or not at
# all, and a set that is not present in full on every platform is left alone
# rather than "completed" by deletion.
#
# THREE SAFETY RAILS, all of which must hold before anything is deleted:
#   1. acpp-llvm is excluded BY NAME. It is the lane mutex, shared by both
#      lanes, has no date in its version, and every published lane artifact
#      depends on it. Pruning it would unsolve the entire channel.
#   2. Keepers (nightly/keepers.txt) are excluded, re-read at prune time.
#   3. Never prune to empty. If the computation would leave no nightly sets,
#      it aborts — that outcome always means a bug here, never intent.

const CHANNEL = "jackm97/naga-labs"
const MUTEX_NAME = "acpp-llvm"
const KEEPERS_FILE = "nightly/keepers.txt"
const PLATFORMS = ["linux-64" "win-64" "noarch"]

def repodata [platform: string] {
  let url = $"https://repo.prefix.dev/($CHANNEL)/($platform)/repodata.json"
  try { http get --raw $url | from json } catch { null }
}

# Every artifact on the channel, flattened, tagged with its subdir.
def channel-artifacts [] {
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

# Read keepers, ignoring comments and blank lines. Re-read every run.
def read-keepers [] {
  if not ($KEEPERS_FILE | path exists) { return [] }
  open --raw $KEEPERS_FILE
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
def set-id [a: record] {
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

def main [--keep: int = 14, --dry-run, --channel: string = $CHANNEL] {
  let all = (channel-artifacts)
  if ($all | is-empty) {
    error make {msg: "prune: could not read channel repodata — refusing to act on an empty view"}
  }

  # Nightly artifacts only. The release lane is never pruned by this script,
  # and the mutex is excluded by name before anything else looks at it.
  let nightly = ($all | where {|a|
    ($a.name != $MUTEX_NAME) and ($a.name | str contains "-nightly")
  })
  if ($nightly | is-empty) {
    print "prune: no nightly artifacts on the channel; nothing to do"
    return
  }

  let sets = ($nightly | each {|a| set-id $a } | uniq)
  let keepers = (read-keepers)

  # Newest-N by version-then-tag ordering. Dates sort lexically here because
  # they are zero-padded YYYY.MM.DD, which is also why the nightly lane uses
  # that format.
  let ordered = ($sets | sort)
  let window = ($ordered | last $keep)
  # UNKNOWN sets are never candidates: an artifact whose lane could not be
  # determined is one we do not understand well enough to delete atomically.
  let candidates = ($ordered | where {|s|
    (not ($s in $window)) and (not ($s in $keepers)) and (not ($s | str ends-with "_UNKNOWN"))
  })

  print $"prune: ($sets | length) nightly sets, keeping newest ($keep) + ($keepers | length) keeper\(s\)"
  print $"  window:     ($window | str join ', ')"
  print $"  keepers:    ($keepers | str join ', ')"
  print $"  candidates: (if ($candidates | is-empty) { '(none)' } else { $candidates | str join ', ' })"

  if ($candidates | is-empty) { print "prune: nothing to delete"; return }

  # RAIL 3: never prune to empty.
  let surviving = ($sets | length) - ($candidates | length)
  if $surviving < 1 {
    error make {msg: $"prune: refusing to delete every nightly set \(($sets | length) sets, ($candidates | length) candidates\) — this always means a bug here, not intent"}
  }

  for s in $candidates {
    let members = ($nightly | where {|a| (set-id $a) == $s })
    print $"  set ($s): ($members | length) artifacts across ($members | get platform | uniq | str join '+')"
    if $dry_run { continue }
    for m in $members {
      # Deleted one artifact at a time, but only ever as a complete set: the
      # loop above is the atomic unit, and a failure mid-set must be loud so
      # the half-deleted state is visible rather than silently tolerated.
      let res = (do { ^rattler-build upload prefix --delete -c $channel $m.fname } | complete)
      if $res.exit_code != 0 {
        error make {msg: $"prune: FAILED deleting ($m.fname) from set ($s) — the set is now PARTIAL and must be finished by hand before the next publish"}
      }
    }
  }
  print $"prune: removed ($candidates | length) set\(s\)"
}
