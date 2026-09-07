source ${RECIPE_DIR}/build_scripts.sh
source $RECIPE_DIR/get_cpu_arch.sh

mkdir -p ${PREFIX}/etc/conda/{de,}activate.d
cp "${SRC_DIR}"/activate-clang.sh ${PREFIX}/etc/conda/activate.d/activate-${PKG_NAME}.sh
cp "${SRC_DIR}"/deactivate-clang.sh ${PREFIX}/etc/conda/deactivate.d/deactivate-${PKG_NAME}.sh

# THIS PACKAGE SHIPS NO BINARIES. The activation exports CC=${CHOST}-clang, and
# the triplet-prefixed drivers are acpp-clang_impl_${cross_target_platform}'s
# content — upstream's split, where clangdev owns those symlinks on a native
# build. This recipe declares that package as a run dependency instead of
# creating the names itself; two packages shipping bin/${CHOST}-clang is an
# install-time clobber.
