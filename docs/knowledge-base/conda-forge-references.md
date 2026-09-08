# conda-forge references

Source material for how conda-forge builds and ships compiler toolchains.
Read these before working a platform.

## Documentation

- Infrastructure — compilers and runtimes:
  <https://conda-forge.org/docs/maintainer/infrastructure/#compilers-supplied-by-conda-forge>
- Infrastructure — more on compiler feedstocks:
  <https://conda-forge.org/docs/maintainer/infrastructure/#more-on-compiler-feedstocks>
- conda-build — Anaconda compiler tools:
  <https://docs.conda.io/projects/conda-build/en/latest/resources/compiler-tools.html>
- Pinned dependencies — globally pinned packages:
  <https://conda-forge.org/docs/maintainer/pinning_deps/#globally-pinned-packages>
- Knowledge base — OpenMP:
  <https://conda-forge.org/docs/maintainer/knowledge_base/#openmp>

## Global pinning

- `conda_build_config.yaml`:
  <https://github.com/conda-forge/conda-forge-pinning-feedstock/blob/main/recipe/conda_build_config.yaml>
- Feedstock: <https://github.com/conda-forge/conda-forge-pinning-feedstock>

## Compiler feedstocks

Activation packages install `etc/conda/activate.d` scripts; implementation
packages install the compilers themselves.

| Feedstock | Role |
|---|---|
| [ctng-compiler-activation](https://github.com/conda-forge/ctng-compiler-activation-feedstock/) | Linux activation: GCC and Clang |
| [ctng-compilers](https://github.com/conda-forge/ctng-compilers-feedstock) | Linux implementation: GCC |
| [clang-compiler-activation](https://github.com/conda-forge/clang-compiler-activation-feedstock/) | macOS activation: Clang |
| [clang-win-activation](https://github.com/conda-forge/clang-win-activation-feedstock/) | Windows activation: Clang and clang-cl |
| [cuda-nvcc](https://github.com/conda-forge/cuda-nvcc-feedstock) | CUDA compiler and activation — see its [activate.sh](https://github.com/conda-forge/cuda-nvcc-feedstock/blob/main/recipe/activate.sh) |

## LLVM component feedstocks

| Feedstock | Role |
|---|---|
| [llvmdev](https://github.com/conda-forge/llvmdev-feedstock) | LLVM libraries and command-line tools |
| [clangdev](https://github.com/conda-forge/clangdev-feedstock) | Clang libraries, drivers and tools |
| [compiler-rt](https://github.com/conda-forge/compiler-rt-feedstock) | builtins, sanitizers, profile, BlocksRuntime |
| [libcxx](https://github.com/conda-forge/libcxx-feedstock) | LLVM C++ standard library |
| [openmp](https://github.com/conda-forge/openmp-feedstock) | `llvm-openmp` runtime |
| [lld](https://github.com/conda-forge/lld-feedstock) | LLVM linker |
| [cctools-and-ld64](https://github.com/conda-forge/cctools-and-ld64-feedstock) | macOS assembler, archiver and linker |

## Related feedstocks named by the docs

- Windows MSVC activation: <https://github.com/conda-forge/vc-feedstock>
- Fortran on Windows: <https://github.com/conda-forge/flang-feedstock>
- Convenience compiler metapackages: <https://github.com/conda-forge/compilers-feedstock>
- Rust: [activation](https://github.com/conda-forge/rust-activation-feedstock) ·
  [implementation](https://github.com/conda-forge/rust-feedstock)
- Go: [activation](https://github.com/conda-forge/go-activation-feedstock) ·
  [implementation](https://github.com/conda-forge/go-feedstock)

## AdaptiveCpp build documentation

The build we produce follows these, not the conda-forge recipes.

- Building and installing: <https://github.com/AdaptiveCpp/AdaptiveCpp/blob/develop/doc/installing.md>
- LLVM dependency: <https://github.com/AdaptiveCpp/AdaptiveCpp/blob/develop/doc/install-llvm.md>
- Compilation flows: <https://github.com/AdaptiveCpp/AdaptiveCpp/blob/develop/doc/compilation.md>
- Backends: [CUDA](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/develop/doc/install-cuda.md) ·
  [ROCm](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/develop/doc/install-rocm.md) ·
  [Level Zero](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/develop/doc/install-spirv.md) ·
  [OpenCL](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/develop/doc/install-ocl.md) ·
  [Vulkan](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/develop/doc/install-vulkan.md) ·
  [Metal](https://github.com/AdaptiveCpp/AdaptiveCpp/blob/develop/doc/install-metal.md)
- C++ standard parallelism: <https://github.com/AdaptiveCpp/AdaptiveCpp/blob/develop/doc/stdpar.md>
- Using acpp: <https://github.com/AdaptiveCpp/AdaptiveCpp/blob/develop/doc/using-acpp.md>
- Doc index: <https://github.com/AdaptiveCpp/AdaptiveCpp/tree/develop/doc>

## Package to feedstock mapping

- Browsable: <https://conda-forge.org/feedstock-outputs/>
- Registry: <https://github.com/conda-forge/feedstock-outputs>
- One package: `outputs/<a>/<b>/<c>/<name>.json` under
  <https://raw.githubusercontent.com/conda-forge/feedstock-outputs/main/>

The registry lists every feedstock that has ever produced a package name, so
an entry with several feedstocks reflects a package split that moved.
