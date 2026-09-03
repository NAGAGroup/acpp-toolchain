#!/usr/bin/env nu
# Record this month's first green nightly build-set as a permanent keeper.
#
#   nu shared/record-keeper.nu [--dry-run] [--keepers-file nightly/keepers.txt]
#
# KEEPER POLICY (Jack-ratified 2026-08-09): the first GREEN set of each calendar
# month is kept forever, exempt from newest-N pruning. This script is the
# implementation of that policy. Until 2026-09-02 there was none — the policy
# was enforced by a person remembering, and nightly/keepers.txt claimed
# otherwise.
#
# WHERE IT RUNS, AND WHY THAT IS THE ONLY CORRECT PLACE. From the `retention`
# job of nightly.yml, BEFORE the prune step. A keeper names a set that is
# complete on BOTH platforms, and `retention` is the only job that gates on both
# platform publishes — the per-platform publish jobs each see half a set and
# would record a keeper for something that does not exist yet. Running before
# the prune is equally deliberate: recording the keeper is what makes the prune
# safe, so this failing must stop the job before anything is deleted.
#
# WHAT IT WRITES. One line in the file's existing format, "<date>_llvm<version>"
# — no platform, no build number. A build string names a PACKAGE, not a set:
# within a single platform the ten outputs of one set carry several different
# build strings, so a keeper carrying one would protect one package and leave
# its nine siblings prunable, which is exactly the partial-set unsolvability the
# whole set abstraction exists to prevent.
#
# THE RULE. Append if and only if NO existing keeper line already names a set in
# the same calendar month. Deliberately not "if the file is empty" and not "one
# line per month, enforced by rewriting": August currently holds TWO keeper
# lines and both must survive, because 2026.08.10_llvm21.1.8 was added by hand
# and is load-bearing for the template project's committed lock. This rule is
# also what makes the script idempotent — a second run in the same month finds
# the month already recorded and writes nothing.
#
# WHERE THE SET ID COMES FROM. Recomputed from the published channel repodata,
# using the same code the pruner uses to decide what to delete, so the keeper
# records what was ACTUALLY published rather than what a job output claimed.

use channel-sets.nu [KEEPERS_FILE nightly-artifacts read-keepers set-id set-month SET_PLATFORMS]

def main [--dry-run, --keepers-file: string = $KEEPERS_FILE] {
  let nightly = (nightly-artifacts)
  if ($nightly | is-empty) {
    # This runs only after two green publishes, so an empty nightly view means
    # the channel read failed or the publish did not land. Either way, refusing
    # is right: the next step is a deletion pass.
    error make {msg: "record-keeper: no nightly artifacts visible on the channel — refusing to record or to let the prune step run"}
  }

  let sets = ($nightly | each {|a| set-id $a } | uniq | sort)
  let newest = ($sets | last)
  print $"record-keeper: ($sets | length) nightly set\(s\) on the channel; newest = ($newest)"

  # An id we could not parse is one we do not understand well enough to promote
  # to permanent. The pruner already refuses to delete these; recording one
  # would write a keeper that protects nothing.
  if ($newest | str ends-with "_UNKNOWN") {
    error make {msg: $"record-keeper: newest set ($newest) has no parseable lane tag — refusing to record it"}
  }

  # A keeper is a promise about a COMPLETE set. Assert the set is actually on
  # both platforms before promising to keep it forever.
  let members = ($nightly | where {|a| (set-id $a) == $newest })
  let present = ($members | get platform | uniq | sort)
  let missing = ($SET_PLATFORMS | where {|p| not ($p in $present) })
  print $"  members: ($members | length) artifacts across ($present | str join '+')"
  if not ($missing | is-empty) {
    error make {msg: $"record-keeper: set ($newest) is missing on ($missing | str join ', ') — a keeper must name a set complete on both platforms"}
  }

  let month = (set-month $newest)
  let keepers = (read-keepers $keepers_file)
  let already = ($keepers | where {|k| (set-month $k) == $month })
  print $"  month: ($month); existing keepers: (if ($keepers | is-empty) { '(none)' } else { $keepers | str join ', ' })"

  if not ($already | is-empty) {
    print $"record-keeper: ($month) already has a keeper \(($already | str join ', ')\) — nothing to record"
    emit-output ""
    return
  }

  let comment = $"# First green set of ($month), recorded automatically by the retention job(run-suffix)."
  print $"record-keeper: recording ($newest) as the first green set of ($month)"
  if $dry_run {
    print "  DRY RUN — would append:"
    print $"    ($comment)"
    print $"    ($newest)"
    emit-output $newest
    return
  }

  let existing = (open --raw $keepers_file)
  let sep = if ($existing | str ends-with "\n") { "" } else { "\n" }
  $"($existing)($sep)($comment)\n($newest)\n" | save --force $keepers_file
  print $"record-keeper: appended to ($keepers_file)"
  emit-output $newest
}

# Provenance for the generated comment, when CI can supply it.
def run-suffix [] {
  let id = ($env.GITHUB_RUN_ID? | default "")
  if $id == "" { "" } else { $" \(run ($id)\)" }
}

# Let the calling workflow step name the set in its commit message without
# re-deriving it. Silent outside CI.
def emit-output [id: string] {
  let target = ($env.GITHUB_OUTPUT? | default "")
  if $target == "" { return }
  # Only separate from a PREVIOUS entry: a leading blank line into an empty
  # file is harmless but makes the file confusing to read in a failed run.
  let prior = (if ($target | path exists) { open --raw $target } else { "" })
  let sep = if (($prior != "") and (not ($prior | str ends-with "\n"))) { "\n" } else { "" }
  $"($sep)keeper=($id)\n" | save --append $target
}
