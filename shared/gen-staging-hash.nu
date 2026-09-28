#!/usr/bin/env nu
# Keep the staging cache honest.
#
# rattler-build keys the staging cache on SHA(resolved requirements +
# referenced variant variables) ONLY. It does NOT hash the sources, the
# patches, or the staging build script — verified 2026-08-08: adding a patch
# left the key byte-identical, so the patched source was never compiled and
# CI kept reproducing an already-fixed bug (and, worse, files that already
# exist in the cache are packaged from the CACHE, so output-script edits to
# them are silently discarded).
#
# So we hash those inputs ourselves into a variant variable the staging
# output references, which makes the key rotate whenever they change.
# CI runs this with --check, so a stale hash fails the build instead of
# silently shipping a stale toolchain.
#
#   nu shared/gen-staging-hash.nu           # write the hash into the variants
#   nu shared/gen-staging-hash.nu --check   # exit 1 if a variant file is stale

const VARIANTS = ["shared/variants/linux-64.yaml", "shared/variants/win-64.yaml", "shared/variants/linux-aarch64.yaml", "shared/variants/osx-arm64.yaml", "shared/variants/win-arm64.yaml"]

# The `source:` block of the recipe: everything the staging output fetches
# (URLs, sha256s, git revs, patch lists) but that the key ignores.
def source-block [recipe: path] {
  let lines = (open --raw $recipe | lines)
  let start = ($lines | enumerate | where {|r| $r.item =~ '^    source:' } | get -o 0.index)
  if $start == null { return "" }
  let rest = ($lines | skip ($start + 1))
  let stop = ($rest | enumerate | where {|r| $r.item =~ '^    [a-z]' } | get -o 0.index)
  let body = (if $stop == null { $rest } else { $rest | first $stop })
  $body | str join "\n"
}

def compute [] {
  let root = ($env.FILE_PWD | path dirname)
  mut parts = []
  # patches, in a stable order
  for f in (ls ($root | path join "shared" "patches") | get name | sort) {
    $parts = ($parts | append (open --raw $f))
  }
  # the staging build script itself
  $parts = ($parts | append (open --raw ($root | path join "shared" "build-stage.nu")))
  # the recipe's staging source spec, as written (the rev is a template, so
  # the text is stable per commit; the rendered rev is in rattler's own key)
  let recipe = ($root | path join "recipe.yaml")
  if ($recipe | path exists) { $parts = ($parts | append (source-block $recipe)) }
  $parts | str join "\n---\n" | hash sha256 | str substring 0..15
}

def main [--check] {
  let root = ($env.FILE_PWD | path dirname)
  let want = (compute)
  mut stale = false
  for v in $VARIANTS {
    let p = ($root | path join $v)
    let text = (open --raw $p)
    let updated = (if ($text | str contains "staging_inputs:") {
      $text | lines | each {|l| if ($l | str starts-with "staging_inputs:") { $"staging_inputs: [\"($want)\"]" } else { $l } } | str join "\n" | $in + "\n"
    } else {
      $text | str trim --right | $in + $"\nstaging_inputs: [\"($want)\"]\n"
    })
    if $check {
      if $text != $updated { print --stderr $"($v) has a stale staging_inputs hash — run `pixi run gen-staging-hash`"; $stale = true }
    } else {
      $updated | save --force $p
      print $"($v): staging_inputs = ($want)"
    }
  }
  if $check {
    if $stale { exit 1 }
    print "staging_inputs hashes are up to date"
  }
}
