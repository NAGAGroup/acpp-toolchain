#!/bin/bash

set -e -x

source "${RECIPE_DIR}"/build.sh

mkdir -p "${PREFIX}"/etc/conda/{de,}activate.d/
cp "${SRC_DIR}"/rendered/activate-clang.sh "${PREFIX}"/etc/conda/activate.d/activate_"${PKG_NAME}".sh
cp "${SRC_DIR}"/rendered/deactivate-clang.sh "${PREFIX}"/etc/conda/deactivate.d/deactivate_"${PKG_NAME}".sh

# THIS PACKAGE SHIPS NO BINARIES. The activation exports CC=${CHOST}-clang, and
# the triplet-prefixed drivers are acpp-clang_impl_${cross_target_platform}'s
# content — upstream's split, where clangdev owns those symlinks on a native
# build. This recipe declares that package as a run dependency instead of
# creating the names itself; two packages shipping bin/${CHOST}-clang is an
# install-time clobber.
