# init-local-channel.nu — make ./local-channel SOLVABLE before anything is
# published into it.
#
# WHY IT IS NEEDED AT ALL. `pixi publish --to ./local-channel` writes packages
# into a directory; a channel is a directory of SUBDIRS each carrying a
# repodata.json. Without the index, the output is a pile of .conda files that
# no solve can see — so anyone wanting to INSTALL what was just built (the
# whole point of a local channel) needs this first.
#
# ⚠ `./local-channel` IS NOT A DECLARED CHANNEL in pixi.toml, and this script is
# why that decision is safe rather than an omission. Measured 2026-09-07:
# adding it to `[workspace] channels` breaks EVERY environment solve until the
# directory exists — including the `packaging` environment that runs THIS
# script, which makes the fix circular — and writes an absolute,
# machine-specific `file:///…/local-channel/` URL into the committed lock.
# Publishing to a directory needs no channel entry; installing from it needs
# an index, which is what this creates.
#
# NOARCH IS ALWAYS CREATED. Every conda channel must have a noarch subdir even
# when nothing in it is noarch; solvers read it unconditionally.
#
# THE INDEX FILES ARE NEVER COMMITTED — local-channel/ is git-ignored. This
# script is the reproducible way to get them back, which is the point: an
# artifact that must exist and must not be committed needs a command, not a
# note in a README.
#
#   pixi run -e packaging nu tools/init-local-channel.nu --platform linux-64
#   pixi run -e packaging nu tools/init-local-channel.nu --platform win-64 --channel ./local-channel

const EMPTY_REPODATA = {
  info: {},
  packages: {},
  "packages.conda": {},
  repodata_version: 1,
}

def main [
  --platform: string           # the target platform subdir to create alongside noarch
  --channel: string = "./local-channel"
] {
  if ($platform | is-empty) {
    error make {msg: "init-local-channel: --platform <p> is required — a channel with no platform subdir is not solvable for that platform"}
  }
  if $platform not-in ["linux-64" "win-64" "osx-arm64" "noarch"] {
    error make {msg: $"init-local-channel: ($platform) is not one of this workspace's platforms"}
  }

  let subdirs = (["noarch" $platform] | uniq)
  for subdir in $subdirs {
    let dir = ($channel | path join $subdir)
    mkdir $dir
    let index = ($dir | path join "repodata.json")
    if ($index | path exists) {
      # NEVER overwrite a populated index: a real publish writes one, and
      # clobbering it would empty a channel someone is mid-way through using.
      let existing = (open $index)
      let n = (($existing.packages? | default {} | columns | length)
             + ($existing."packages.conda"? | default {} | columns | length))
      print $"init-local-channel: ($subdir) already indexed, ($n) package\(s\) — left alone"
      continue
    }
    ($EMPTY_REPODATA | merge {info: {subdir: $subdir}}) | to json --indent 2 | save -f $index
    print $"init-local-channel: created ($index)"
  }
  print $"init-local-channel: ($channel) is a valid empty channel for noarch + ($platform)"
}
