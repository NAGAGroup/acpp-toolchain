# Point the consumer at the PUBLISHED toolchain: one platform, and every
# @ACPP_VERSION@ (compiler stems and the naga-acpp host dependency) set to the
# version just published — the same idea as ../suite/pin-published.nu.
#
#   nu pin-published.nu <platform> <version>
def main [platform: string, version: string] {
  let f = ($env.FILE_PWD | path join "pixi.toml")
  let out = (open --raw $f
    | str replace --regex '(?m)^platforms = .*$' $'platforms = ["($platform)"]'
    | str replace --all '@ACPP_VERSION@' $version)
  $out | save --force $f
  print $out
}
