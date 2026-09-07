# Vendored feedstocks — what is forked, what is lifted, and from where

Every conda-forge feedstock this toolchain draws on falls into exactly one of
two classes, and the class decides how it appears in this tree. The test is
Jack's: **fork it only if we must CHANGE it or must REBUILD it against our
LLVM.**

Both classes record the upstream commit they came from. Without that, "diff
against upstream" degrades into guesswork within months — which is the whole
reason for forking rather than rewriting.

## Class A — real submodules under `vendor/`

Edited in place; each becomes its own pixi source package via a wrapper
manifest under `packages/` (the wrapper lives OUTSIDE the submodule because
`pixi publish` skips any subdirectory carrying its own `[workspace]`, and
feedstocks do ship `pixi.toml` files).

Their pinned upstream commit is the submodule gitlink itself — `git -C
vendor/<name> log`, not a `PINNED_REF` file. Each submodule carries an
`upstream` remote pointing at conda-forge, so `git diff upstream/main` is a
one-liner.

| Submodule | Gives us | Pinned at (fork point) | Recipe format |
|---|---|---|---|
| `ctng-compiler-activation-feedstock` | linux activation → `acpp-clang_linux-64`, `acpp-clangxx_linux-64` | `8595ae16ec1f9b72a945965102924c780cee717b` | rattler `recipe.yaml` |
| `clang-win-activation-feedstock` | win activation incl. clang-cl → `acpp-clang_win-64`, `acpp-clangxx_win-64`, `acpp-clang-cl_win-64` | `19f75a409cb15ec850cd108b5aff4c0c2c260965` | rattler `recipe.yaml` |
| `clang-compiler-activation-feedstock` | **osx** activation → `acpp-clang_osx-arm64`, `acpp-clangxx_osx-arm64` | `2659b5a3de067087a20234b109d60cb3c7c7b681` | **conda-build `meta.yaml`** |

**RETIRED: `llvm-spirv-feedstock`** (fork point
`d62a8f68d3506468939b4e27c16357bcf6fa979c`, conda-build `meta.yaml`). It is no
longer a submodule. The E2E methodology lifts in-tree, so the translator now
lives at `packages/_acpp-llvm-spirv-stage` plus its four slicers, and the fork
is reachable through this repository's history and through
`NAGAGroup/llvm-spirv-feedstock` itself. Archiving, not deleting.

One of the three remaining is still conda-build `meta.yaml`, not rattler
`recipe.yaml`. `pixi-build-rattler-build` consumes a `recipe.yaml`, so the osx
activation needs a format conversion on top of the rename — more work than the
two that are already rattler-format.

**Which feedstock owns which platform is not guessable**, and reading "the
obvious one" produces a wrong model: `clang_linux-*` comes from *ctng*
(the linux clang activation is literally `cp activate-gcc.sh
activate-clang.sh` plus a sed), `clang_osx-*` from `clang-compiler-activation`,
and the NATIVE `clang_impl_*` from `clangdev`.

### Superseded: the partial vendor copies

`shared/activation/vendor/` on `main` held hand-copied subsets of two of these
feedstocks. The submodules above replace them. Their refs, recorded so the
current published packages remain traceable:

- `ctng-compiler-activation` @ `52080ff3c70082b3d8e84d93af8d7caa89194298`
- `clang-win-activation` @ `d9ca09e6610c5cffdfece4486f0f0e0963cc023b`

### Porting facts, measured on this tree (2026-09-05)

Probed by temporarily flipping `publish = true` on the linux wrapper and
running `pixi publish --dry-run` (the flip was not committed):

1. **The wrapper -> submodule wiring WORKS.** `package.build.config.recipe`
   resolved `../../vendor/ctng-compiler-activation-feedstock/recipe/recipe.yaml`
   and the backend rendered it. The manifest-outside-the-fork shape is proven,
   not assumed.
2. **A feedstock's own `recipe/conda_build_config.yaml` is NOT read.** The
   render failed on `cross_target_platform` being undefined — a key ctng
   supplies from its own cbc, zipped with `triplet`, `cross_stdlib` and
   `cross_stdlib_version`, alongside `gcc_version`, `clang_version` and
   `MACOSX_SDK_VERSION`. pixi feeds a build only the workspace's
   `build-variants-files` (plus any `-m`), so **every variant key a vendored
   recipe reads must be lifted into `../variants.yaml`** — deliberately, not
   wholesale: upstream's `cross_target_platform` list alone would generate a
   cross matrix over eight targets.
3. `pixi publish` really does WALK the tree for manifests, and it walks
   `recipe.yaml` files too, not only `pixi.toml` — the first dry-run on this
   branch failed inside the OLD `release/recipe.yaml` (an undefined
   `staging_inputs`, a key that lived in the retired per-platform variant
   files). That is why the legacy lane directories do not exist on this
   branch. A subdirectory carrying its own `[workspace]` IS skipped, which is
   why `shared/tests/gpu-smoke/` is inert.

## Class B — lift-sources

Forked on GitHub into `NAGAGroup` for diffability, but deliberately NOT
submoduled. acpp component mode injects `-DLLVM_EXTERNAL_PROJECTS=AdaptiveCpp
-DLLVM_EXTERNAL_ADAPTIVECPP_SOURCE_DIR=<path>
-DLLVM_ADAPTIVECPP_LINK_INTO_TOOLS=ON` into a SINGLE cmake configure of the
LLVM tree, and `LLVM_EXTERNAL_PROJECTS` is an llvm-tree option while
`add_clang_library` / `add_llvm_pass_plugin` are in-tree macros — so
conda-forge's `llvmdev`→`clangdev` split cannot carry acpp. The compiler core
is unavoidably ONE build. We fork these to inherit their PATCHES AND FLAGS,
which is where the value is, and copy what we need into our own core recipe.

Each lift has a directory under `packages/acpp-core/lifts/<name>/` holding a
`PINNED_REF` (the upstream commit the lift was taken from) and `NOTES` (what
we took and why). See those files; this table is the index.

| Lift | Fork | What we want from it |
|---|---|---|
| `llvmdev` | `NAGAGroup/llvmdev-feedstock` | `0001-pass-through-QEMU_LD_PREFIX-SDKROOT.patch`, the osx `AddLLVM.cmake` SONAME sed, and the flag set |
| `clangdev` | `NAGAGroup/clangdev-feedstock` | the NINE conda-integration patches we do not have |
| `compiler-rt` | `NAGAGroup/compiler-rt-feedstock` | build flags and layout |
| `lld` | `NAGAGroup/lld-feedstock` | build flags |
| `lldb` | `NAGAGroup/lldb-feedstock` | build flags; lldb is core on EVERY platform incl. Windows |
| `openmp` | `NAGAGroup/openmp-feedstock` | build flags |
| `polly` | `NAGAGroup/polly-feedstock` | build flags. Linux-only in our build, and ships no named binary — its artifacts ride the library carves |
| `clang-tools-extra` | — (no separate feedstock) | lives INSIDE `clangdev-feedstock`: a `clang-tools-extra/*` source entry feeding its `clang-tools` output |
| `bolt` | — **our own `main` @ `22bf38e`** | conda-forge packages no BOLT at all, but we SHIP it: `bin/llvm-bolt`, `llvm-bolt-heatmap`, `perf2bolt`, `merge-fdata` are include globs in `acpp-tools` and asserted in its `package_contents` test. The lift source is our own history, not upstream. ELF-only: linux gets it, win and osx do not — expressed as a `skip:`, never an omission |

## Class C — depend on conda-forge, do not fork

`osx-sysroot` (owns `sdkroot_env_*` and `macosx_deployment_target_*`), `vc`
(owns `vs2022_win-64`; there is no vs2022-feedstock), `linux-sysroot`,
`cctools-and-ld64`, `binutils`, `level-zero` / `level-zero-devel`, `ocl-icd`,
`compilers` (a USER convenience metapackage — our recipes must depend on the
concrete activation package, never on the aggregate), `libcxx`.

`stdlibs` is a false friend: it is a Python package listing standard-library
module names and has nothing to do with `c_stdlib`. The real `c_stdlib` /
`c_stdlib_version` mechanism is a variant key, and it is set in
`variants.yaml`.

## Naming — the hard rule

**Nothing ships under a conda-forge name.** A forked `llvmdev` publishes as
`acpp-llvm-dev`, never `llvmdev`. Channel priority is a preference for DIRECT
specs, but a TRANSITIVE requirement for a name our channel provides is
EXCLUDED by strict channel priority — a hard solve failure, not a
fall-through. Our own published `fmt` broke our own spdlog-1.14 cell exactly
this way.

The vendored recipes above are still upstream's and still publish upstream
names. Renaming every output is a precondition of publishing them, which is
why their wrapper manifests carry `publish = false` today.
