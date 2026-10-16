# Point the consumer at the PUBLISHED toolchain: one platform, and every
# @ACPP_VERSION@ (compiler stems and the naga-acpp host dependency) set to the
# version just published — the same idea as ../suite/pin-published.nu.
#
#   nu pin-published.nu <platform> <version>
def main [platform: string, version: string] {
  # x86-64 platforms (linux-64, win-64): packages need the __archspec x86_64_v3 virtual package declared.
  let plat = (if $platform in ["linux-64", "win-64"] {
    '{ platform = "' + $platform + '", archspec = "x86_64_v3" }'
  } else { '"' + $platform + '"' })
  let plat_line = ('platforms = [' + $plat + ']')
  let f = ($env.FILE_PWD | path join "pixi.toml")
  let out = (open --raw $f
    | str replace --regex '(?m)^platforms = .*$' $plat_line
    | str replace --all '@ACPP_VERSION@' $version)
  $out | save --force $f
  print $out
}
