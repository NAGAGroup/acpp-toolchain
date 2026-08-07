# install-activation.nu <clang|clangxx> — installs the activation scripts
# for one side of the acpp compiler activation split.
def main [side: string] {
  let p = $env.PREFIX
  mkdir ($p | path join "etc" "conda" "activate.d")
  mkdir ($p | path join "etc" "conda" "deactivate.d")
  cp $"shared/activation/activate-acpp-($side).sh" ($p | path join "etc" "conda" "activate.d")
  cp $"shared/activation/deactivate-acpp-($side).sh" ($p | path join "etc" "conda" "deactivate.d")
  if $side == "clangxx" {
    mkdir ($p | path join "share" "acpp" "toolchain")
    cp shared/activation/acpp-toolchain.cmake ($p | path join "share" "acpp" "toolchain")
  }
}
