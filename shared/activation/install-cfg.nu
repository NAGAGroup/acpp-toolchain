#!/usr/bin/env nu
# install-cfg.nu — write clang's triple-named config files into $PREFIX/bin.
#
# Clang looks for <default-triple>-<driver>.cfg beside itself (its own
# executable directory), so shipping these lets a bare `clang` invocation
# find --sysroot/-isystem/-L/-rpath with NO activation script and NO
# environment variable — the file is <CFGDIR>-relative (see the templates in
# cfg/), so it survives conda's prefix relocation for free.
#
# Templates in cfg/*.tmpl are the triple-generic form of the files restored
# from archive/overhaul:packaging/cfg/x86_64-conda-linux-gnu-clang{,++,-cpp}.cfg
# (read via `git show`, not a checked-out branch), with @TRIPLE@ substituted
# here.
#
# Usage: nu install-cfg.nu <triple> <sysroot:true|false>
#   (sysroot is a nushell bool: pass a bare true or false, not a quoted string)
#   sysroot=true  (linux): the full template — clang/clang++ end in
#                 --sysroot=<CFGDIR>/../<triple>/sysroot, clang-cpp gets
#                 -isystem plus --sysroot (it never links).
#   sysroot=false (osx): --sysroot and -Wl,-rpath-link lines are DROPPED —
#                 there is no glibc-shaped sysroot on macOS (the SDK comes
#                 from SDKROOT, set by the sdkroot_env activation, not by
#                 this file), and -rpath-link is a GNU-ld-only flag that
#                 ld64 does not understand. clang-cpp keeps only -isystem.
def main [triple: string, sysroot: bool] {
  let here = $env.FILE_PWD
  let cfg_dir = ($here | path join "cfg")
  let bindir = ($env.PREFIX | path join "bin")
  mkdir $bindir

  let drivers = [
    {tmpl: "clang.cfg.tmpl", out: $"($triple)-clang.cfg"}
    {tmpl: "clang++.cfg.tmpl", out: $"($triple)-clang++.cfg"}
    {tmpl: "clang-cpp.cfg.tmpl", out: $"($triple)-clang-cpp.cfg"}
  ]

  for d in $drivers {
    let raw = (open --raw ($cfg_dir | path join $d.tmpl) | str replace --all "@TRIPLE@" $triple)
    let lines = ($raw | lines)
    let filtered = (if $sysroot {
      $lines
    } else {
      $lines | where {|l|
        (not ($l | str starts-with "--sysroot=")) and (not ($l | str starts-with "$-Wl,-rpath-link,"))
      }
    })
    $filtered | str join "\n" | save --force ($bindir | path join $d.out)
    print $"install-cfg: wrote ($d.out)"
  }
}
