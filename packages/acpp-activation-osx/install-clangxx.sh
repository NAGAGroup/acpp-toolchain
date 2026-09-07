#!/bin/bash

set -e -x

source "${RECIPE_DIR}"/build.sh

mkdir -p "${PREFIX}"/etc/conda/{de,}activate.d/
cp "${SRC_DIR}"/rendered/activate-clang++.sh "${PREFIX}"/etc/conda/activate.d/activate_"${PKG_NAME}".sh
cp "${SRC_DIR}"/rendered/deactivate-clang++.sh "${PREFIX}"/etc/conda/deactivate.d/deactivate_"${PKG_NAME}".sh

# THIS PACKAGE SHIPS NO BINARIES — see install-clang.sh. bin/${CHOST}-clang++ is
# acpp-clangxx_impl_${cross_target_platform}'s content, declared as a run
# dependency in the recipe.
