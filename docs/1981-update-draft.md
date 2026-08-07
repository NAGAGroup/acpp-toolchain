# Draft: AdaptiveCpp discussion #1981 update post (for Jack to review/post)

Hi all — the conda packaging effort from this thread is now complete and
productionized. What changed since February:

**New home + new shape.** The packages are now built from
[NAGAGroup/acpp-toolchain](https://github.com/NAGAGroup/acpp-toolchain) and
the family got a redesign — it is now a complete, standalone LLVM
toolchain, not just a SYCL compiler:

- `acpp` — the compiler (acpp, clang, lld, llvm binutils, SYCL headers)
- `acpp-runtime` — runtime libs + JIT (the only thing consumer envs need;
  arrives automatically via run-exports)
- `acpp-tools` (clang-format/tidy/clangd/BOLT), `acpp-lldb` (LLDB),
  `acpp-llvm-dev` (LLVM API headers/static libs)
- `acpp-clang_linux-64` / `acpp-clangxx_linux-64` — real conda compiler
  activation (sysroot, glibc-2.28 floor, run-exports) — usable as
  `cxx_compiler = ["acpp-clangxx"]` in conda-build/pixi variant systems
- **Opt-in backend runtime metapackages**, per the core-binary +
  optional-backends direction discussed here: `acpp-runtime-cuda`,
  `acpp-runtime-intel` (note: renamed from the `acpp-toolchain-cuda`
  naming I floated earlier — these augment the runtime, not the compiler)

**Two lanes.** `acpp-*` tracks releases (currently v25.10.0 + LLVM
20.1.8 — the newest LLVM that release supports); `acpp-*-nightly` tracks
develop daily (currently LLVM 21.1.8). The lanes are mutually exclusive
per environment, and the nightly gives you upstream's newest work
(e.g. LLVM 21 support) within 24h.

**Honesty corner — AMD.** The ROCm backend is currently *not* shipped:
the generic JIT requires acpp's LLVM ≤ ROCm's LLVM, and conda-forge's HIP
runtime is still ROCm 6.3 (LLVM 18), so no installable configuration
exists. The moment conda-forge's ROCm ≥ 7.2 stack lands, the backend and
an `acpp-runtime-rocm` metapackage ship in a rebuild.

**Validation.** Every release is gated on AdaptiveCpp's own test suite
(built against the installed packages, generic SSCP, 335 cases passing)
plus solver-level audits of the packaging constraints (e.g. conda-forge
clang/llvm of a *different* major stays co-installable; same-major is
cleanly rejected instead of clobbering).

Install story is unchanged: install pixi, add
`https://prefix.dev/jackm97/naga-labs`, `pixi add acpp`. Windows support
via the linked-into-LLVM flow is next on the roadmap.

Feedback welcome — especially from anyone who wants the AMD path
prioritized once conda-forge's ROCm 7.2 lands.
