# NGCSimLib

[![CI](https://github.com/CognitiveSubstratesAI/NGCSimLib/actions/workflows/CI.yml/badge.svg)](https://github.com/CognitiveSubstratesAI/NGCSimLib/actions/workflows/CI.yml)
[![Docs (stable)](https://img.shields.io/badge/docs-stable-blue.svg)](https://cognitivesubstratesai.github.io/NGCSimLib/stable/)
[![Docs (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://cognitivesubstratesai.github.io/NGCSimLib/dev/)
[![Code Style: Blue](https://img.shields.io/badge/code%20style-blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![ColPrac](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)
[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg)](https://opensource.org/licenses/BSD-3-Clause)

**Julia port of [NACLab](https://www.cs.rit.edu/~ago/nac_lab.html)'s
[`ngc-sim-lib`](https://github.com/NACLab/ngc-sim-lib).** The substrate layer
(Component / Compartment / Context / Process) for biophysical /
neurobiological simulation graphs. JIT compilation via
[Reactant.jl](https://github.com/EnzymeAD/Reactant.jl); automatic
differentiation via [Enzyme.jl](https://github.com/EnzymeAD/Enzyme.jl).

This is **Layer 0** of the NGC stack:

| Layer | Package | Status | Upstream |
|---|---|---|---|
| 0 (substrate) | **NGCSimLib** (this) | substrate complete; JIT working | [ngc-sim-lib](https://github.com/NACLab/ngc-sim-lib) |
| 1 (zoo) | NGCLearn.jl | scaffold next | [ngc-learn](https://github.com/NACLab/ngc-learn) |
| 2 (PC framework) | FabricPC.jl | later | [FabricPC](https://github.com/trueagi-io/FabricPC) |

End-to-end acceptance is verified against
[ngc-museum](https://github.com/NACLab/ngc-museum) exhibits — exhibit-by-exhibit
reproduction is the gate for each "phase done."

## What it gives you

- **Compartment** — typed handle into a flat global-state dict; reads and writes are routed through one mutable singleton.
- **Component** — user-defined biophysical unit (neuron layer, synapse bank). Subtype `AbstractComponent` directly or use `@ngc_component` for the boilerplate-free version.
- **`@compilable` method bodies** — captured as `Expr` at definition time and rewritten by the Parser into pure `(ctx; kwargs...) → ctx` functions.
- **Context** — scope manager with do-block syntax (`Context("net") do ctx … end`); auto-registers every Component constructed inside it and wires compartments to their full paths.
- **MethodProcess / JointProcess** — ordered chains of `@compilable` calls; one Julia-eager runner via `compile_process!`, one JIT runner via `compile_with_reactant!`. Same shape, swap-in JIT.

## Installation

NGCSimLib requires **Julia 1.12+** (uses `OncePerProcess` for module-level
singletons — see [docs/decisions.md](docs/decisions.md) §1).

```julia
using Pkg
Pkg.add(url = "https://github.com/CognitiveSubstratesAI/NGCSimLib")
```

## Quick example

```julia
using NGCSimLib

# Define a tiny biophysical component
mutable struct RateNeuron <: NGCSimLib.AbstractComponent
    name::String
    context_path::String
    args::Vector{Any}
    kwargs::Dict{Symbol,Any}
    voltage::NGCSimLib.Compartment
end

NGCSimLib.@compilable function advance!(c::RateNeuron, dt)
    NGCSimLib.set!(c.voltage, NGCSimLib.get_value(c.voltage) .+ dt)
    return c
end

# Build the model under a Context — compartments auto-wire to "net:layer1:voltage"
NGCSimLib.Context("net") do _ctx
    cell = RateNeuron("layer1", "", Any[], Dict{Symbol,Any}(),
                      NGCSimLib.Compartment([0.0, 0.0, 0.0]))
    NGCSimLib.post_init!(cell)

    process = NGCSimLib.MethodProcess(name="step")
    process >> (cell, :advance!)
    NGCSimLib.post_init!(process)
end

# Eager run
process = NGCSimLib.get_processes(NGCSimLib.get_context("net"))["step"]
NGCSimLib.compile_process!(process)
ctx_out, _ = NGCSimLib.run(process; dt=0.5)
@info ctx_out["net:layer1:voltage"]   # [0.5, 0.5, 0.5]
```

For traced JIT execution via Reactant, see
[`examples/03_reactant_jit.jl`](examples/03_reactant_jit.jl).

## Documentation

- [Stable docs](https://cognitivesubstratesai.github.io/NGCSimLib/stable/) — releases
- [Dev docs](https://cognitivesubstratesai.github.io/NGCSimLib/dev/) — `main`
- [`docs/decisions.md`](docs/decisions.md) — cross-cutting design decisions log
- [`docs/specs/`](docs/specs/) — per-module port specifications from upstream Python
- [`docs/NGCSimLib_design.md`](docs/NGCSimLib_design.md) — architecture deep-dive

## Examples

Working code in [`examples/`](examples/):

| File | Demonstrates |
|---|---|
| [`01_hello_compartment.jl`](examples/01_hello_compartment.jl) | Define a Component, wire it under a Context, read/write Compartments. |
| [`02_method_process.jl`](examples/02_method_process.jl) | Chain `@compilable` methods through a MethodProcess; eager run. |
| [`03_reactant_jit.jl`](examples/03_reactant_jit.jl) | Same as 02 but `compile_with_reactant!` for traced JIT execution. |

Run any example with `julia --project=. examples/<file>.jl`.

## Project structure

```
NGCSimLib/
├── src/
│   ├── support/        # Logger, Priority, Deprecators, Config, IO, Modules, Help
│   ├── core/           # GlobalState, Compartment, Operations, Component,
│   │                   # Context, ContextManager, ContextAware
│   ├── parser/         # ContextTransformer, KwargsTransformer, Parser
│   └── process/        # BaseProcess, MethodProcess, JointProcess
├── test/               # 341 tests (incl. concurrent + Reactant integration)
├── docs/
│   ├── decisions.md    # cross-cutting design decisions log
│   ├── specs/          # per-module port specs from upstream Python
│   └── src/            # Documenter source
└── examples/           # runnable demonstrations (see above)
```

## Contributing

This project follows [ColPrac](https://github.com/SciML/ColPrac). Code style is
[Blue](https://github.com/invenia/BlueStyle); run
`julia --project=. -e 'using JuliaFormatter; format(".")'` before submitting.

For non-obvious design decisions, please read or update
[`docs/decisions.md`](docs/decisions.md).

## License

BSD-3-Clause. Matches the upstream `ngc-sim-lib` license (NACLab, RIT).
Copyright © 2026 CognitiveSubstrates AI.

## Citation

If you use this work, please also cite the upstream `ngc-sim-lib`:

```bibtex
@article{ororbia2022neural,
  title   = {The neural coding framework for learning generative models},
  author  = {Ororbia, Alexander and Kifer, Daniel},
  journal = {Nature Communications},
  volume  = {13},
  number  = {1},
  pages   = {2064},
  year    = {2022}
}
```
