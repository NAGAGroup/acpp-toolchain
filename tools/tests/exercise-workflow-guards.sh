#!/bin/bash
# Exercise the two BASH guards in staging.yml — the version gate and the
# platform-matrix builder — against bad and good input. Both snippets are
# copied verbatim from the workflow; if they drift, this test drifts with them,
# which is why the report says which lines they came from.
set -uo pipefail
fails=0
ok()   { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fails=$((fails+1)); }

# ---- GATE 1: the version guard --------------------------------------------
version_guard() {   # $1 = value of ACPP_NIGHTLY_DATE ("" means unset)
  ACPP_NIGHTLY_DATE="$1" ACPP_BUILD_NUMBER=0 bash -c '
    set -euo pipefail
    if [ -z "${ACPP_NIGHTLY_DATE:-}" ] || [ "$ACPP_NIGHTLY_DATE" = "0.dev0" ]; then
      echo "ACPP_NIGHTLY_DATE is unset or is the local-render placeholder — refusing to build." >&2
      exit 1
    fi
    echo "Building $ACPP_NIGHTLY_DATE build $ACPP_BUILD_NUMBER"
  ' >/dev/null 2>&1
}
version_guard "" ;              [ $? -ne 0 ] && ok "gate 1 FAILS on an unset version"      || bad "gate 1 passed on an unset version"
version_guard "0.dev0" ;        [ $? -ne 0 ] && ok "gate 1 FAILS on the 0.dev0 placeholder" || bad "gate 1 passed on 0.dev0"
version_guard "2026.09.07" ;    [ $? -eq 0 ] && ok "gate 1 passes on a real date"           || bad "gate 1 rejected a real date"

# ---- setup: the platform matrix builder -----------------------------------
matrix() {          # $1 = the platforms input
  PLATFORMS="$1" bash -c '
    set -euo pipefail
    entries=()
    for p in $PLATFORMS; do
      case "$p" in
        linux-64)   entries+=("{\"platform\":\"linux-64\",\"runner\":\"Linux-x64-64\",\"expect_names\":44,\"expect_skips\":12,\"expect_artifacts\":46}") ;;
        win-64)     entries+=("{\"platform\":\"win-64\",\"runner\":\"Win-x64-64\",\"expect_names\":37,\"expect_skips\":20,\"expect_artifacts\":39}") ;;
        osx-arm64)  entries+=("{\"platform\":\"osx-arm64\",\"runner\":\"macOS-26-xlarge\",\"expect_names\":42,\"expect_skips\":14,\"expect_artifacts\":44}") ;;
        *) echo "Unknown platform '"'"'$p'"'"'" >&2; exit 1 ;;
      esac
    done
    if [ ${#entries[@]} -eq 0 ]; then echo "No platform selected" >&2; exit 1; fi
    printf "matrix={\"include\":[%s]}\n" "$(IFS=,; echo "${entries[*]}")"
  ' 2>/dev/null
}
out=$(matrix "linux-64 win-64 osx-arm64")
if [ $? -eq 0 ] && [ "$(echo "$out" | grep -o 'platform' | wc -l)" = "3" ]; then
  ok "matrix builds all three platforms"; echo "     $out"
else bad "matrix failed on the default input"; fi

out=$(matrix "linux-64"); [ $? -eq 0 ] && ok "matrix builds a single platform" || bad "matrix failed on one platform"
matrix "linux64" >/dev/null 2>&1;   [ $? -ne 0 ] && ok "matrix FAILS on a typo'd platform name" || bad "matrix accepted a typo"
matrix "" >/dev/null 2>&1;          [ $? -ne 0 ] && ok "matrix FAILS on an empty selection"     || bad "matrix accepted an empty selection"
matrix "linux-64 fedora" >/dev/null 2>&1; [ $? -ne 0 ] && ok "matrix FAILS when ONE token of several is unknown" || bad "matrix accepted a partly-bad list"

echo
[ $fails -eq 0 ] && echo "ALL WORKFLOW BASH GUARDS BEHAVE" || { echo "$fails FAILURES"; exit 1; }
