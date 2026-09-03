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

# The channel view — what a set IS, how it is identified, and how keepers are
# read — lives in one place, shared with shared/record-keeper.nu. See the header
# of that module for why this is not duplicated per caller.
use channel-sets.nu [CHANNEL channel-artifacts nightly-artifacts read-keepers set-id]

def main [--keep: int = 14, --dry-run, --channel: string = $CHANNEL] {
  let all = (channel-artifacts)
  if ($all | is-empty) {
    error make {msg: "prune: could not read channel repodata — refusing to act on an empty view"}
  }

  # Nightly artifacts only. The release lane is never pruned by this script,
  # and the mutex is excluded by name inside nightly-artifacts.
  let nightly = (nightly-artifacts)
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
