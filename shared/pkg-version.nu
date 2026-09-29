# Print the version of the naga-acpp package in ./local-channel and write it
# as a GitHub step output, so publish/test jobs can pin the exact package.
def main [] {
  let files = (glob "local-channel/*/naga-acpp-[0-9]*.conda")
  if ($files | is-empty) { error make {msg: "no naga-acpp-<version>-*.conda under local-channel/"} }
  let v = ($files | first | path basename | str replace 'naga-acpp-' '' | split row '-' | first)
  print $"naga-acpp version: ($v)"
  $"version=($v)\n" | save --append $env.GITHUB_OUTPUT
}
