#!/usr/bin/env nu
#
# upstream-paths.nu — print the exact file list conda-forge's own artifact for a
# package ships, at a pinned version, on a given platform.
#
# WHY THIS EXISTS. Every upstream feedstock builds ONE project into its OWN
# prefix, so a slice expressed as `bin/*` is unambiguous there. Our
# `_acpp-stage` is a single cmake install of llvm + clang + clang-tools-extra +
# lld + lldb + openmp + compiler-rt + AdaptiveCpp into ONE tree, which removes
# exactly the scoping those globs relied on: against our stage `bin/*` selects
# llvm's tools, clang's drivers, lld, lldb and acpp all at once.
#
# So for any slice rooted at a SHARED directory (bin, lib, libexec, share) the
# glob is not the contract — the SHIPPED SET is, and it is published. This tool
# reads it: `info/paths.json` inside the .conda is the artifact's exact
# manifest. The output is pasted into the consuming recipe's ACPP_CARVE list
# with our version substituted, and the recipe says it took that route.
#
# Usage:
#   nu tools/upstream-paths.nu <name> <version> <platform>
#   nu tools/upstream-paths.nu clang-tools 21.1.8 linux-64
#
# Needs bsdtar (libarchive) and pixi; run it in the `dev` environment.
#
# Artifacts are cached under ~/.cache/acpp-upstream-artifacts so that repeating
# a query is free and so a reviewer can re-read the same bytes we did.

const CACHE = "~/.cache/acpp-upstream-artifacts"

# `pixi search` prints a human report, not data. The URL line is the one field
# we need and it is stable; parsing it is cheaper and far less brittle than
# fetching and filtering a full repodata.json (~200 MB for conda-forge linux-64).
def resolve-url [name: string, version: string, platform: string] {
  let report = (^pixi search $"($name)==($version)"
    --channel https://prefix.dev/conda-forge
    --platform $platform
    | complete)
  if $report.exit_code != 0 {
    error make {msg: $"pixi search failed for ($name)==($version) on ($platform):\n($report.stderr)"}
  }
  let url = ($report.stdout
    | lines
    | where {|l| $l | str starts-with "URL" }
    | each {|l| $l | str replace -r '^URL\s+' '' | str trim }
    | first)
  if ($url | is-empty) {
    error make {msg: $"no URL in the search report for ($name)==($version) on ($platform) — does that build exist?"}
  }
  # The version is asserted against the URL, not trusted from the query: a spec
  # that matches nothing must fail loudly rather than silently hand back the
  # newest build of a different version, which is what a bare search does.
  let file = ($url | path basename)
  if not ($file | str starts-with $"($name)-($version)-") {
    error make {msg: $"resolved ($file), which is not ($name) ($version) — refusing to read the wrong artifact"}
  }
  $url
}

def fetch [url: string] {
  let cache = ($CACHE | path expand)
  mkdir $cache
  let dest = ($cache | path join ($url | path basename))
  if not ($dest | path exists) {
    print -e $"fetching ($url)"
    http get --raw $url | save -f $dest
  }
  $dest
}

# A .conda is a zip holding two zstd tarballs: `info-<pkg>.tar.zst` carries the
# metadata, `pkg-<pkg>.tar.zst` the content. Only the info member is read, so
# nothing is ever unpacked to disk.
def paths-of [archive: string] {
  let json = (^bsdtar -xOf $archive "info-*.tar.zst" | ^bsdtar -xOf - "info/paths.json" | from json)
  $json.paths | get _path | sort
}

def main [name: string, version: string, platform: string] {
  let url = (resolve-url $name $version $platform)
  print -e $"artifact: ($url)"
  let paths = (paths-of (fetch $url))
  print -e $"($paths | length) paths"
  $paths | each {|p| print $p }
}
