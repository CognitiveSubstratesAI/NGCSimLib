# Installation

NGCSimLib requires **Julia 1.12 or later** — uses `OncePerProcess` for
module-level singletons (see [`docs/decisions.md`](https://github.com/CognitiveSubstratesAI/NGCSimLib/blob/main/docs/decisions.md) §1).

## From GitHub (current — pre-registration)

```julia
using Pkg
Pkg.add(url = "https://github.com/CognitiveSubstratesAI/NGCSimLib")
```

## Verify the install

```julia
using NGCSimLib
@info "NGCSimLib version $(NGCSimLib.NGCSIMLIB_VERSION)"
```

## Dev install

To work on the package itself:

```bash
git clone https://github.com/CognitiveSubstratesAI/NGCSimLib.git
cd NGCSimLib
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

## Compute backend

NGCSimLib depends on:

- **[Reactant.jl](https://github.com/EnzymeAD/Reactant.jl)** for JIT compilation to MLIR/StableHLO (analog of JAX's `jit`)
- **[Enzyme.jl](https://github.com/EnzymeAD/Enzyme.jl)** for automatic differentiation (analog of JAX's `grad`)

Both work on CPU by default. GPU support follows Reactant's backend matrix.
