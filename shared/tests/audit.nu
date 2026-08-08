# audit.nu — solver-level constraint audits against ./local-channel.
# Usage: nu shared/tests/audit.nu [--platform linux-64|win-64]
# Each case creates a throwaway pixi workspace and asserts solve/conflict.

def try-solve [platform: string, name: string, deps: list<string>, should_solve: bool] {
  let dir = (mktemp -d)
  let dep_lines = ($deps | each {|d| $'($d) = "*"' } | str join "\n")
  $'[workspace]
name = "audit"
channels = ["file://(pwd)/local-channel", "https://prefix.dev/jackm97/naga-labs"]
platforms = ["($platform)"]

[dependencies]
($dep_lines)
' | save ($dir | path join "pixi.toml")
  let res = (do { cd $dir; ^pixi lock } | complete)
  let solved = ($res.exit_code == 0)
  let ok = ($solved == $should_solve)
  let verdict = (if $ok { "PASS" } else { "FAIL" })
  print $"[($verdict)] ($name): solved=($solved) expected=($should_solve)"
  rm -rf $dir
  $ok
}

def linux-cases [] {
  [
    # 1. suite installs together
    ["suite coherent", [acpp acpp-tools acpp-lldb acpp-runtime-cuda], true],
    # 2. same-major conda-forge clang rejected next to runtime
    ["same-major libllvm rejected", [acpp-runtime libllvm20], false],
    ["same-major clang rejected", [acpp clang], false],
    # 3. different-major conda-forge tools allowed
    ["different-major clang-tools allowed", [acpp-runtime clang-tools], true],
    # 4. lane mixing rejected
    ["lane mixing rejected", [acpp-runtime acpp-runtime-nightly], false],
    ["lane mixing rejected (compiler)", [acpp acpp-nightly], false],
    # 5. activation pair
    ["activation pair", [acpp-clang_linux-64 acpp-clangxx_linux-64], true],
    # 6. mixed-compiler env stays solvable (gcc CC + acpp CXX)
    ["gcc + acpp-clangxx mixed", [gcc_linux-64 acpp-clangxx_linux-64], true]
  ]
}

def win-cases [] {
  [
    # 1. suite installs together (no lldb on win)
    ["suite coherent", [acpp acpp-tools acpp-runtime-cuda], true],
    # 2. same-major conda-forge clang rejected next to the compiler
    ["same-major clang rejected", [acpp clang], false],
    # 3. conda-forge clang-format shadowing rejected by acpp-tools
    ["clang-format rejected next to tools", [acpp-tools clang-format], false],
    # 4. lane mixing rejected (vacuous until nightly win publishes, then real)
    ["lane mixing rejected", [acpp-runtime acpp-runtime-nightly], false],
    ["lane mixing rejected (compiler)", [acpp acpp-nightly], false],
    # 5. activation pair
    ["activation pair", [acpp-clang_win-64 acpp-clangxx_win-64], true],
    # 6. clang-cl activation is an ALTERNATIVE, not an addition
    ["clang-cl activation solo", [acpp-clang-cl_win-64], true],
    ["clang-cl + clang activation conflict", [acpp-clang-cl_win-64 acpp-clang_win-64], false]
  ]
}

def main [--platform: string = "linux-64"] {
  let cases = (if $platform == "win-64" { win-cases } else { linux-cases })
  mut results = []
  for c in $cases {
    $results = ($results | append (try-solve $platform $c.0 $c.1 $c.2))
  }
  if ($results | all {|r| $r}) { print "ALL AUDITS PASS" } else { error make {msg: "audit failures"} }
}
