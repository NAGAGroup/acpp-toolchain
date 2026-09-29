# Point the suite at the PUBLISHED packages: one platform, no local-channel
# entry, every naga-acpp* dependency pinned to exact version + build number.
def main [platform: string, version: string, build_number: string] {
  let f = ($env.FILE_PWD | path join "pixi.toml")
  let out = (open --raw $f
    | str replace --regex '(?m)^platforms = .*$' $'platforms = ["($platform)"]'
    | str replace '"../../../local-channel", ' ''
    | str replace --all --regex '(?m)^(naga-acpp[A-Za-z0-9_-]*) = "\*"' $'${1} = { version = "==($version)", build = "*_($build_number)" }')
  $out | save --force $f
  print $out
}
