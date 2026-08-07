#!/usr/bin/env bash
_acpp_restore() {
    local var="$1"; local bak="CONDA_BACKUP_ACPP_${var}"; local val="${!bak:-}"
    if [ -z "${val}" ] || [ "${val}" = "__CONDA_ACPP_UNSET__" ]; then unset "${var}" 2>/dev/null || true
    else export "${var}=${val}"; fi
    unset "${bak}" 2>/dev/null || true
}
for v in CMAKE_ARGS ACPP_CLANG ACPP_COMPILER_DIR ACPP_TARGETS DEBUG_CXXFLAGS CXXFLAGS CXX; do _acpp_restore "$v"; done
_P="${CONDA_PREFIX:-}"
if [ -n "${_P}" ]; then rm -f "${_P}/bin/clang++.cfg" "${_P}/bin/x86_64-conda-linux-gnu-clang++.cfg"; fi
unset _P; unset -f _acpp_restore
