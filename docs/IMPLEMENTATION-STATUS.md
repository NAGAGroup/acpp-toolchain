# Implementation status

Working notes. Design: naga-labs/SYCLBUILDKIT-DESIGN.md (v3 delta ratified
2026-08-07 by executive decision). Delete when rollout completes.

## v3 (2026-08-07, branch v3) — staging recipes + canonical activation + CI
- release/recipe.yaml + nightly/recipe.yaml: ONE multi-output staging recipe
  per lane (staging output builds LLVM+acpp once; outputs carve via files:
  globs; --experimental). Per-package dirs + shared/build.nu REMOVED.
- Tasks: pixi run {render,build}-{release,nightly} (dev env, direct
  rattler-build, --no-build-id).
- Canonical activation: vendored ctng-compiler-activation-feedstock @
  52080ff3 (VERIFIED provenance of clang{,xx}_linux-64 — gcc templates +
  clang transforms); shared/activation/render-install.sh = verbatim port,
  ACPP delta = 3 _tc_activation entries (CXX side). Round-trip tested.
  TODO: CI render-diff gate vs shipped clangxx_linux-64 artifact.
- CI: .cirun.yml (Azure D8ads_v7 eastus; bump on quota), smoke.yml,
  release.yml (render gate -> cirun build -> artifacts), nightly.yml
  (develop-HEAD skip, ACPP_NIGHTLY_DATE versioning). Publish = OIDC
  trusted publishing, stubbed until channel registration.
- GPU gate policy: CI = CPU gates only; RTX-4090 CUDA smoke local before
  channel promotion.

# ---- pre-v3 notes below (historical) ----

## Done
- Workspace skeleton (single root manifest, package-only members)
- shared/build.nu: pinned-fetch + persistent per-lane cache
  (.build-cache/<lane>/), stable -S/-B incremental cmake, spirv-redirect
  script patch, licenses, triple symlinks
- Release lane: all 9 packages (runtime, acpp, llvm-dev, tools, lldb,
  clang/clangxx activation, cuda/intel metapackages)
- Nightly lane: 7 packages (metapackages are lane-agnostic, live in release/)
- Fixes en route: libxml2-devel (conda-forge header split),
  cuda-nvcc-tools (FindCUDAToolkit anchor), nu regex replacement escaping,
  configure gate on build.ninja

## Release lane: BUILT + SMOKE-TESTED ✓ (2026-08-07)
- All 9 packages built; SYCL hello PASSES on CPU (omp) AND NVIDIA RTX 4090
  (CUDA JIT via packaged opt/llc + driver PTX JIT + libdevice symlink)
- Opt-in verified: bare env has NO cuda; ze/ocl fail soft; +acpp-runtime-cuda
  enables GPU
- Key fixes landed: JIT tools (opt/llc/lld) belong to acpp-runtime;
  stable-symlink indirection for the persistent cache incl. find-result
  stability (CMAKE_PREFIX_PATH via links only) + relocatable prefix baking
  (INSTALL_PREFIX/CUDA paths use real placeholder) + reconfigure-on-prefix-
  change + SPIRV-subbuild refresh; rattler-index needs repodata deleted to
  re-read same-name rebuilt files; pixi package cache must be purged when
  rebuilding same version+build

## COMPLETE (2026-08-07): both lanes built, tested, publish-ready
- Release (25.10.0_llvm20.1.8): 9 pkgs. Nightly (2026.08.07_llvm21.1.8,
  develop @ HEAD): 7 pkgs. All in output/linux-64 (tested artifacts).
- Gates ALL PASS:
  * package contents (16/16)
  * partition co-install: 9 pkgs, zero clobbers
  * solver audits: same-major cf clang/llvm REJECTED; different-major
    clang-tools ALLOWED; gcc+acpp-clangxx mixed SOLVED; cf lldb REJECTED;
    lane mixing REJECTED (both pairs); nightly suite coherent
  * SYCL smoke: acpp driver + CMake add_sycl_to_target + plain $CXX —
    CPU AND NVIDIA RTX 4090 (CUDA JIT), BOTH lanes
  * upstream acpp test suite: 335 cases, no errors (release lane)
  * python_abi + cudart leaks fixed; bare env exactly: acpp family +
    llvm-openmp + numactl

## BLOCKED on Jack: publish auth
Stored prefix.dev token returns 401. With a fresh API key:
    export PREFIX_API_KEY=<key>
    cd ~/projects/acpp-toolchain
    for f in output/linux-64/*.conda; do pixi upload prefix --channel code-accelerate "$f"; done
Then channel cleanup (web UI or API): yank naga-* (9 pkgs) and the old
acpp-{libs,toolchain,clang-tools} trio; then archive
CodeAccelerate-SYCLBuildKit with a pointer README.

## Remaining phases (per design §11)
- win-64 (phase 2): build.nu win branches + win recipes; CI-driven
  (upstream windows-acppllvm.yml is the reference); Jack validates on WSL host
- CI lanes are WRITTEN (.github/workflows/) but unexercised — first
  dispatch will need iteration (esp. GH runner disk/ccache sizing)
- #1981 update post: draft at docs/1981-update-draft.md for Jack

## Next
- Carve verification across all 5 toolchain slices (partition = no
  overlap, no strays) → adjust globs
- publish-local + solver audits (same-major cf rejected, different-major
  allowed, lane mixing rejected, metapackage envs solve)
- SYCL hello smoke (generic/omp) via both activation paths
- acpp test suite gate (upstream tests/, generic, CPU)
- Nightly lane build (LLVM 21.1.8 + develop HEAD)
- Publish dry-run → prefix.dev (needs auth on this machine)
- win-64 recipes + CI (CI last per ruling)
- README/docs, channel cleanup (yank naga-*), #1981 draft for Jack

## Notes / decisions made in flight
- Nightly version: date via ACPP_NIGHTLY_DATE env at render
  (0.dev0 placeholder locally)
- Boost drop CONFIRMED (configure passed without it)
- lldb python scripting ON => swig+python build deps

## Follow-up (Jack, 2026-08-07 check-in)
- Refactor external projects to pixi source packages (template external/
  pattern) instead of build.nu-fetched sources: SPIRV translator becomes
  `acpp-llvm-spirv` (built against acpp-llvm-dev; acpp-runtime run-dep;
  removes the ExternalProject patch + last in-build fetch); OpenCL
  headers as env-provided find. Isolated, non-breaking swap post-E2E.
