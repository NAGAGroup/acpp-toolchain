# check-glob-normalisation.nu — every glob in this tree goes through
# `glob-native`, which normalises backslashes to forward slashes.
#
# WHY. On Windows `path join` emits BACKSLASHES, and a backslash is an ESCAPE
# character in a nushell glob pattern — so a pattern built from `path join`
# does not merely fail to match, it fails to PARSE:
#
#   × error with glob pattern — failed to parse glob expression
#
# That killed the win-64 stage at its first fixup (run 34129107780), in a branch
# that had never executed anywhere before the idempotency harness learned to run
# it. Forward slashes are valid separators on Windows, so normalising is correct
# on every platform.
#
# THIS IS THE PART THAT CANNOT REGRESS. Fixing the sites was a sweep; this is
# the property, and it fails on a laptop the moment a new bare `glob` appears —
# which matters because linux can never reproduce the failure itself: `path
# join` only emits backslashes on Windows, so the defect is INVISIBLE to every
# local run and every linux CI job.
#
#   pixi run -e packaging nu tools/check-glob-normalisation.nu

# This file obeys its own rule.
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
  # ⚠ AND THE RESULTS ARE NORMALISED TOO, which is the other half. On Windows
  # glob RETURNS backslash paths (or verbatim ones), so a caller comparing a
  # result against a forward-slash root — `path relative-to`, `str starts-with`,
  # `=~` — fails with `prefix not found` even though the pattern was fine. Win
  # run 34134434830 died in exactly that way, in the harness's own snapshot,
  # AFTER the fixups themselves had passed. Both sides of every comparison must
  # be forward-slash, and returning them normalised is the one place that makes
  # every caller correct at once.
  let hits = (if $no_dir { glob $p --no-dir } else { glob $p })
  $hits | each {|h| $h | str replace '\\?\' '' | str replace --all '\' '/' }
}

# ⚠ STRING LITERALS ARE NOT CODE. The word "glob" appears in error messages and
# prints all over this tree — carve.nu's "glob matched nothing" among them — and
# a checker that reads them as call sites reports the tree as broken when it is
# the MODEL that is wrong. Same lesson as the carve/stage checker that invented
# 23 collisions by ignoring ACPP_CARVE_EXCLUDE: model all of the semantics, or
# do not claim to model any.
def strip-strings [line: string] {
  $line | str replace --all --regex '"[^"]*"' '""' | str replace --all --regex "'[^']*'" "''"
}

def main [] {
  let files = (glob-native "packages/**/*.nu" | append (glob-native "tools/**/*.nu"))
  if ($files | length) < 15 {
    error make {msg: $"check-glob-normalisation: only ($files | length) scripts found — that is a broken scan"}
  }

  mut offenders = []
  mut helpers = 0
  mut calls = 0
  for f in $files {
    let rel = ($f | path relative-to (pwd))
    let lines = (open --raw $f | lines)
    let has_helper = ($lines | any {|l| $l =~ '^def glob-native ' })
    if $has_helper { $helpers = $helpers + 1 }
    for r in ($lines | enumerate) {
      let raw = $r.item
      if ($raw | str trim | str starts-with '#') { continue }
      # Code only: a "glob" inside a message is prose, not a call site.
      let l = (strip-strings $raw)
      $calls = $calls + ($raw | parse -r 'glob-native ' | length)
      # A bare `glob` call: the word at a call position, not part of
      # `glob-native`. The ONE legitimate occurrence is inside the helper's own
      # body, which is the line that actually performs the expansion.
      let bare = ($l =~ '(?:^|[ (|])glob ') and (not ($l =~ 'glob-native'))
      if not $bare { continue }
      if ($l =~ 'if \$no_dir \{ glob \$p --no-dir \} else \{ glob \$p \}') { continue }
      $offenders = ($offenders | append $"($rel):($r.index + 1): ($raw | str trim)")
    }
  }

  print $"check-glob-normalisation: ($files | length) scripts, ($helpers) carry the helper, ($calls) normalised call site\(s\)"
  if $calls < 20 {
    error make {msg: $"check-glob-normalisation: only ($calls) normalised calls — this tree globs far more than that, so the scan is wrong"}
  }
  if not ($offenders | is-empty) {
    for o in $offenders { print $"BARE GLOB ($o)" }
    error make {msg: $"check-glob-normalisation: ($offenders | length) bare glob call\(s\) — each one breaks on Windows when its pattern comes from `path join`"}
  }
  print "check-glob-normalisation: OK — every glob is normalised"
}
