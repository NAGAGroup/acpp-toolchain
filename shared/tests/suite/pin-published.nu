# Point the suite at the PUBLISHED packages: one platform, no local-channel
# entry, every naga-acpp* dependency pinned to exact version + build number.
# The two test packages (pkg-omp, pkg-generic) are pointed at the published
# toolchain the way ../consumer/pin-published.nu does it: one platform, and
# every @ACPP_VERSION@ set to the version just published.
def main [platform: string, version: string, build_number: string] {
  let f = ($env.FILE_PWD | path join "pixi.toml")
  let out = (open --raw $f
    | str replace --regex '(?m)^platforms = .*$' $'platforms = ["($platform)"]'
    | str replace '"../../../local-channel", ' ''
    | str replace --all --regex '(?m)^(naga-acpp[A-Za-z0-9_-]*) = "\*"' $'${1} = { version = "==($version)", build = "*_($build_number)" }')
  $out | save --force $f
  print $out

  for pkg in [pkg-omp pkg-generic] {
    let pf = ($env.FILE_PWD | path join $pkg "pixi.toml")
    let pout = (open --raw $pf
      | str replace --regex '(?m)^platforms = .*$' $'platforms = ["($platform)"]'
      | str replace --all '@ACPP_VERSION@' $version)
    $pout | save --force $pf
    print $"($pkg)/pixi.toml: platform ($platform), version ($version)"
  }
}
