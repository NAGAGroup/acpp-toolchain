# acpp-toolchain — design

How this repository is arranged and why. Durable: it describes decisions, not
progress. Current state, open items and who owes what live in
`IMPLEMENTATION-STATUS.md`; source material for how conda-forge builds
toolchains lives in `knowledge-base/`.

## Two workspaces

`staging/` builds LLVM and AdaptiveCpp **once** and publishes the result as a
single release asset. `packaging/` consumes that asset and slices it into the
packages we ship. They are separate pixi workspaces and never build together.

The split exists because the two halves have wildly different costs. A full
LLVM build is an hour of a large runner; a packaging change is minutes. Keeping
them in one workspace means every packaging mistake risks paying for LLVM
again. Separated, the expensive artifact is built once, frozen, and iterated
against cheaply — a packaging error costs a packaging run and can never cost an
LLVM rebuild.

### The contract between them

`staging/` publishes to a GitHub **release asset**, not a workflow artifact.
Actions artifacts expire, have no stable public URL, and require a token even
on a public repository — rattler has none of those things and simply fetches a
URL. Release assets are permanent, public, and served from a predictable
address.

```
https://github.com/NAGAGroup/acpp-toolchain/releases/download/<tag>/<file>
```

GitHub publishes a sha256 digest for every asset, readable from the API, so
`packaging/` pins the exact bytes without anyone copying a hash by hand.

**The tag is reused while getting a build green, and frozen the moment
`packaging/` pins it.** Reusing a tag replaces the asset behind an unchanged
URL, which silently changes what a pinned hash refers to.

Release assets cap at 2 GiB per file. GitHub's own documentation disagrees with
itself above that — the releases page states a flat 2 GiB, while the large-file
page says the limit follows the repository owner's Git LFS plan, which for
NAGAGroup (Team) is 4 GB. The build fails deliberately at the lower number
rather than discovering the disagreement during a multi-gigabyte upload at the
end of an hour-long build. The artifact is currently ~323 MB, so this is
headroom, not a constraint.

## What `staging/` produces

One conda package, `acpp-stage`, containing the whole toolchain tree: LLVM,
clang, lld, lldb, openmp, compiler-rt, AdaptiveCpp, the SPIR-V translator, and
the ROCm and CUDA runtime pieces the backends need. It is not installable in
any meaningful sense and is not meant to be; it is the tree every published
package carves from.

## ROCm: selection by destination

TheRock's distribution contains **two** install prefixes — ROCm's own at the
root, and a complete LLVM at `lib/llvm` which is AMD's clang toolchain. The
root's `amdgcn` and `llvm` entries are symlinks down into that nested prefix;
everything else at the root is ROCm's own.

We mirror neither prefix. Each wanted item is named, taken from wherever it
happens to live, and placed where it belongs under **one** prefix,
`targets/x86_64-linux`. The source is an implementation detail of AMD's layout;
the destination is the contract with everything that looks for it.

The libraries come from acpp's own HIP deployment manifest
(`ACPP_HIP_DEPLOYMENT_MANIFEST` in its `CMakeLists.txt`), not from our
judgement. Its `hsakmt` entry does not exist in this distribution — newer ROCm
folded it into `libhsa-runtime64` — so acpp writes `HSAKMT_LIBRARY-NOTFOUND`
into the manifest it generates. `hiprtc-builtins` is ours rather than
upstream's: hiprtc loads it at JIT time.

Deliberately absent: the ML and math stack acpp never calls (MIOpen, hipDNN,
hipTensor, rocSPARSE, rocShmem, Tensile's kernels), AMD's LLVM — which acpp's
own `doc/install-rocm.md` recommends against building against — and ~2.4 GB of
static archives. This is also what keeps the package buildable: rattler
relocates every binary it packages and patchelf fails outright on many of those
files.

Symlinks are preserved (`cp -P`). Without that the `.so → .so.N → .so.N.N.N`
chains become three identical files each, and the layout stops being the one
SONAME lookups expect. The selection is ~146 MB from 8.9 GB unpacked, and about
90 MB of that saving is purely from not triplicating libraries.

`AMDDeviceLibsConfig.cmake` is taken from AMD's LLVM prefix rather than the
root's shim, which redirects into a tree we do not ship. Placed at
`lib/cmake/AMDDeviceLibs`, its own three-level walk upward resolves to
`targets/x86_64-linux` and finds the bitcode at exactly the path acpp's default
hint uses.

## Pointing the just-built compiler at conda's toolchain

The compiler we build has no conda configuration of its own, so anything
compiled *with it during the build* — compiler-rt above all — must be told
where the sysroot and GCC installation are.

`LLVM_HOST_TRIPLE` is set to the conda triple. Without it LLVM resolves
`x86_64-unknown-linux-gnu`, and clang's own GCC search then looks under
`lib/gcc/x86_64-unknown-linux-gnu/` and misses conda's. Setting it is what lets
the *installed* compiler find its toolchain with no flags at all, which is why
conda-forge's own clang config files carry no `--gcc-*` option.

Clang configuration files are written into the build tree's `bin/` and are
**never installed** — the shipped compiler's config files belong to the
activation packages. They exist so that everything compiled with the just-built
clang during this build uses the same options as everything else in the
toolchain; a distribution whose own pieces were compiled with different options
is binary-incompatible with itself.

Their names carry the **host triple** — `x86_64-conda-linux-gnu-clang.cfg` —
and that is load-bearing rather than convention. Clang looks first for
`<triple>-<driver>.cfg` using the triple of the target being compiled, so a
host compile finds these and a device compile does not. acpp builds its SSCP
bitcode for `nvptx64-nvidia-cuda`, `spir64-unknown-unknown` and
`amdgcn-amd-amdhsa` with this same clang; a plain `clang.cfg` would be found by
both, and `-march=nocona` is not a thing on NVPTX.

Options prefixed with `$` in a config file go to a **tail list used only when
linking** (`clang/lib/Driver/Driver.cpp`), with the `$` stripped. This is real
syntax and is not in the user manual. It is per-option, not per-line, which is
why `LDFLAGS` is split and each token marked.

`-fno-merge-constants` is removed from what goes into the config files, and
only from there — the outer build keeps it, being driven by conda's gcc which
accepts it. Clang does not, and warns; CMake's `check_compiler_flag` treats
`FAIL_REGEX "optimization flag [^\n]* not supported"` as failure, so with that
flag present **every** feature probe in the compiler-rt configure answers no,
including `-nostdinc++`, which is what keeps libstdc++ out of sanitizer
sources.

## Sub-builds inherit nothing

Three separate cmake invocations run beneath the outer one: LLVM's builtins and
runtimes children, and acpp's SPIR-V translator. None inherits the outer
configuration.

The translator is configured entirely by acpp's own `ExternalProject_Add`, so
nothing LLVM forwards can reach it. Left alone it searches the machine and
finds a distribution LLVM instead of ours. `ACPP_SPIRV_CMAKE_ARGS` (our fork)
hands it the environment's arguments, with `CMAKE_INSTALL_PREFIX` dropped —
acpp installs the translator into a subdirectory and says so through an initial
cache file that a command-line `-D` would override — and the build tree added
to `CMAKE_FIND_ROOT_PATH`, because the LLVM it links lives there while the
find-root modes are `ONLY`.

`RUNTIMES_CMAKE_ARGS` and `BUILTINS_CMAKE_ARGS` are deliberately **not** set.
LLVM already hands those children the just-built compiler, `CMAKE_SYSROOT`,
`LLVM_HOST_TRIPLE`, and the external library locators. Once the config files
supply the toolchain flags there is no demonstrated gap, and both variables
remain available if one appears.

## Virtual packages

The platform is declared as an inline table, not a bare string:

```toml
platforms = [{ platform = "linux-64", glibc = "2.34", cuda = "12.9" }]
```

A bare `"linux-64"` means *the subdir with pixi's default virtual packages*,
and that default is `__glibc = 2.28`. **This, not `c_stdlib_version` in
`variants.yaml`, is what sets the published `__glibc` floor** — changing the
variant key does not move the build hash or the constraint, while changing the
platform declaration does.

2.34 is where glibc merged libpthread into libc, and is the floor recent Level
Zero requires. The Level Zero conda packages do not declare it, so nothing in a
solve corroborates the choice; it is set because it is true.

## Verifying what we shipped

The published artifact is the cheapest instrument available: download it and
read `info/index.json` (the declared dependencies, including `__glibc`) and
`info/hash_input.json` (every variant value that was actually used). That
answers "what did we declare" against the real bytes rather than a render, in
seconds. It is how the glibc question above was settled, and it is how each
`packaging/` output should be checked.

## The fork

`NAGAGroup/AdaptiveCpp`, branch `naga/develop`, pinned by commit in
`staging/variants.yaml`. Changes are made from first principles and kept
upstreamable — each is a small, self-contained correction with its reason in
the commit message. `knowledge-base/` holds the external references behind
these decisions.
