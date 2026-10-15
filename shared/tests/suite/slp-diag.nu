# slp-diag.nu — CI-only diagnostic, no product change.
#
# On the arm lanes (linux-aarch64, osx-arm64) the omp build and the omp/pstl tests of
# round 7 were not deadlocked, they were extremely slow: LLVM 23's SLP vectorizer spends
# minutes on the CBS reduction kernels (BoUpSLP::getLoopNest / buildTreeRec, and on
# osx vectorizeInserts -> tryToVectorizeList -> getTreeCost). This script compiles
# $ACPP_SRC/tests/sycl/reduction.cpp ONCE per variant with the suite's omp-target compile
# and prints how long each variant takes, so the next round can pick the cheapest knob.
#
# Flag set = the T6 set (the suite's own pkg-omp compile of reduction.cpp, reduced to what
# matters): acpp --acpp-targets=omp -O3 -DNDEBUG -DHIPSYCL_DEBUG_LEVEL=2
# -DACPP_ALLOW_INSTANT_SUBMISSION=1, include dirs <tests> and <tests>/sycl, and the
# conda env's include dir for Boost. The compile runs in the suite `build` environment
# (`pixi run -e build nu slp-diag.nu`), where naga-acpp-clangxx_<platform> puts acpp on PATH.
#
# Every variant is capped at 300 s. The cap uses `timeout`, else `gtimeout` (GNU coreutils
# on a macOS runner), else a bash watchdog that kills the whole process tree after the
# deadline (pgrep -P is available on both Linux and macOS).
#
# Usage: nu slp-diag.nu        (needs ACPP_SRC = checkout of the fork, with tests/)

const CAP_SECONDS = 300

# Runs "$@" under the cap and prints EXIT:<code> or EXIT:TIMEOUT as the last line.
# $1 = seconds, $2 = watchdog flag file, rest = the command.
const CAPPED_RUN = '
secs="$1"; flag="$2"; shift 2
rm -f "$flag"
kill_tree() { for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill -KILL "$1" 2>/dev/null; }
if command -v timeout >/dev/null 2>&1; then t=timeout
elif command -v gtimeout >/dev/null 2>&1; then t=gtimeout
else t=""; fi
echo "CAP-TOOL:${t:-bash-watchdog}"
if [ -n "$t" ]; then
  "$t" -k 10 "$secs" "$@"; rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then echo "EXIT:TIMEOUT"; else echo "EXIT:$rc"; fi
else
  "$@" &
  pid=$!
  ( sleep "$secs"; : > "$flag"; kill_tree "$pid" ) &
  wd=$!
  wait "$pid"; rc=$?
  kill_tree "$wd"
  if [ -e "$flag" ]; then echo "EXIT:TIMEOUT"; else echo "EXIT:$rc"; fi
fi
'

def main [] {
  let acpp_src = ($env.ACPP_SRC? | default "")
  if $acpp_src == "" { error make {msg: "slp-diag: ACPP_SRC is not set (checkout of the fork with tests/)"} }
  let tests = ($acpp_src | path join "tests")
  let src = ($tests | path join "sycl" "reduction.cpp")
  if not ($src | path exists) { error make {msg: $"slp-diag: ($src) does not exist"} }
  if (which acpp | is-empty) { error make {msg: "slp-diag: acpp is not on PATH in this environment"} }

  let logdir = ($env.GITHUB_WORKSPACE? | default $nu.temp-path | path join "logs")
  mkdir $logdir
  let work = ($nu.temp-path | path join "slp-diag")
  mkdir $work

  # the conda env's headers (Boost) — the suite gets them through the activation's -isystem $PREFIX/include
  let conda = ($env.CONDA_PREFIX? | default "")
  let boost_inc = (if $conda == "" { [] } else { ["-isystem" ($conda | path join "include")] })

  let base = [
    "acpp" "--acpp-targets=omp" "-O3" "-DNDEBUG"
    "-DHIPSYCL_DEBUG_LEVEL=2" "-DACPP_ALLOW_INSTANT_SUBMISSION=1"
    $"-I($tests)" $"-I($tests | path join sycl)"
  ] ++ $boost_inc

  let variants = [
    {name: "a: default", extra: []}
    {name: "b: -mllvm -slp-cost-loop-trip-count=0", extra: ["-mllvm" "-slp-cost-loop-trip-count=0"]}
    {name: "c: -fno-slp-vectorize", extra: ["-fno-slp-vectorize"]}
    {name: "d: -mllvm -slp-max-vf=4", extra: ["-mllvm" "-slp-max-vf=4"]}
  ]

  print $"slp-diag: acpp = (which acpp | get 0.path), source = ($src), cap = ($CAP_SECONDS) s per variant"
  mut rows = []
  mut i = 0
  for v in $variants {
    $i = $i + 1
    let tag = $"variant-($i)"
    let obj = ($work | path join $"($tag).o")
    let log = ($logdir | path join $"slp-diag-($tag).log")
    let cmd = $base ++ $v.extra ++ ["-c" $src "-o" $obj]
    print $"######## ($v.name)"
    print ($cmd | str join " ")
    let t0 = (date now)
    # the compiler output goes to its own log (it is large); the last line carries the status
    ^bash -c $CAPPED_RUN bash ($CAP_SECONDS | into string) ($work | path join $"($tag).flag") ...$cmd o+e>| tee { save -f $log } | ignore
    let secs = ((((date now) - $t0) | into int) / 1_000_000_000 | math round --precision 1)
    let lines = (open --raw $log | lines | where {|l| $l != "" })
    let status = ($lines | where {|l| $l | str starts-with "EXIT:" } | last 1 | get -o 0 | default "EXIT:?" | str replace "EXIT:" "")
    print ($lines | last 4 | each {|l| $l | str substring 0..200 } | to text)
    $rows = ($rows | append {variant: $v.name, exit: $status, wall_seconds: $secs})
    rm -f $obj
  }

  print "\n==== SLP compile time on reduction.cpp ===="
  print ($rows | table)
}
