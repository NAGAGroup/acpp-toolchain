# audit.nu — solver-level constraint audits against ./local-channel.
# Usage: nu shared/tests/audit.nu   (after `pixi run publish-local`)
# Each case creates a throwaway pixi workspace and asserts solve/conflict.

def try-solve [name: string, deps: list<string>, should_solve: bool] {
  let dir = (mktemp -d)
  let dep_lines = ($deps | each {|d| $'($d) = "*"' } | str join "\n")
  $'[workspace]
name = "audit"
channels = ["file://(pwd)/local-channel", "https://prefix.dev/jackm97/naga-labs"]
platforms = ["linux-64"]

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

def main [] {
  mut results = []
  # 1. suite installs together
  $results = ($results | append (try-solve "suite coherent" [acpp acpp-tools acpp-lldb acpp-runtime-cuda] true))
  # 2. same-major conda-forge clang rejected next to runtime
  $results = ($results | append (try-solve "same-major libllvm rejected" [acpp-runtime libllvm20] false))
  $results = ($results | append (try-solve "same-major clang rejected" [acpp clang] false))
  # 3. different-major conda-forge tools allowed
  $results = ($results | append (try-solve "different-major clang-tools allowed" [acpp-runtime clang-tools] true))
  # 4. lane mixing rejected
  $results = ($results | append (try-solve "lane mixing rejected" [acpp-runtime acpp-runtime-nightly] false))
  $results = ($results | append (try-solve "lane mixing rejected (compiler)" [acpp acpp-nightly] false))
  # 5. activation pair
  $results = ($results | append (try-solve "activation pair" [acpp-clang_linux-64 acpp-clangxx_linux-64] true))
  # 6. mixed-compiler env stays solvable (gcc CC + acpp CXX)
  $results = ($results | append (try-solve "gcc + acpp-clangxx mixed" [gcc_linux-64 acpp-clangxx_linux-64] true))
  if ($results | all {|r| $r}) { print "ALL AUDITS PASS" } else { error make {msg: "audit failures"} }
}
