#!/usr/bin/env nu
# Upload the built local channel to prefix.dev, with the publish-time gates
# that cannot be expressed in a recipe.
#
#   nu shared/publish-channel.nu [--channel jackm97/naga-labs] [--dry-run]
#
# In CI this runs under OIDC trusted publishing, so there is no API key. It is
# wired behind check-no-collision (the C-11 gate) as a `depends-on`, which makes
# that gate unbypassable rather than merely conventional.
#
# Two upload passes, deliberately NOT one:
#
#   * The mutex is republished by every lane run and is expected to already
#     exist, so it uploads with --skip-existing.
#   * Everything else uploads WITHOUT it. A lane package that already exists is
#     a real problem — it means a build number was not bumped and the artifact
#     on the channel is not the one this run built — and it must fail loudly
#     instead of being silently skipped.

const CHANNEL = "jackm97/naga-labs"
const MUTEX_NAME = "acpp-llvm"

def conda-index [pkg: path] {
  let info_glob = "info-*.tar.zst"
  ^unzip -p $pkg $info_glob | ^zstd -d -q -c | ^tar -xO "info/index.json" | from json
}

def main [--channel: string = $CHANNEL, --dry-run] {
  let pkgs = (glob "local-channel/**/*.conda")
  if ($pkgs | is-empty) {
    error make {msg: "publish: no .conda artifacts under local-channel/"}
  }

  # Partition by the package NAME recorded in the artifact, never by filename
  # pattern: "acpp-llvm-dev-25.10.0-...conda" also starts with "acpp-llvm-".
  let tagged = ($pkgs | each {|p| {path: $p, idx: (conda-index $p)} })
  let mutex = ($tagged | where {|t| $t.idx.name == $MUTEX_NAME })
  let rest = ($tagged | where {|t| $t.idx.name != $MUTEX_NAME })

  # ── GATE: the mutex version must be a BARE MAJOR ─────────────────────────
  # `acpp-llvm ==20` is the pin we teach consumers to write. The day this
  # package ships "20.1.8", that pin matches nothing and every downstream
  # environment that used it breaks — silently, at solve time, in someone
  # else's repo. No solve in our own CI would catch it, so it is asserted here
  # against the artifact about to be uploaded.
  for m in $mutex {
    let v = $m.idx.version
    if not ($v =~ '^[0-9]+$') {
      error make {msg: $"publish gate: ($MUTEX_NAME) version must be a bare major, got '($v)' in ($m.path | path basename)"}
    }
  }
  if ($mutex | is-empty) {
    # The lane outputs take the mutex as a host dep, so a channel without it is
    # unsolvable for every consumer. Shipping a lane without its mutex is worse
    # than shipping nothing.
    error make {msg: $"publish gate: no ($MUTEX_NAME) artifact in local-channel — lane packages would be unsolvable"}
  }
  print $"publish gate: ($mutex | length) mutex artifact\(s\) OK, versions = ($mutex | each {|m| $m.idx.version } | uniq | str join ', ')"

  if $dry_run {
    print "DRY RUN — would upload:"
    for t in $mutex { print $"  [skip-existing] ($t.path | path basename)" }
    for t in $rest { print $"  [strict]        ($t.path | path basename)" }
    return
  }

  # Mutex: expected to exist already on every run after the first.
  ^rattler-build upload prefix -c $channel --skip-existing ...($mutex | get path)

  # Lane artifacts: a collision here is a missing build-number bump. Fail loud.
  ^rattler-build upload prefix -c $channel ...($rest | get path)

  print $"published ($tagged | length) artifacts to ($channel)"
}
