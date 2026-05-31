# NGCSimLib

**Julia port of [NACLab](https://www.cs.rit.edu/~ago/nac_lab.html)'s
[`ngc-sim-lib`](https://github.com/NACLab/ngc-sim-lib).** The substrate layer
of the NGC stack — Component / Compartment / Context / Process — for building
biophysical and neurobiological simulation graphs in Julia. JIT compilation
via [Reactant.jl](https://github.com/EnzymeAD/Reactant.jl), automatic
differentiation via [Enzyme.jl](https://github.com/EnzymeAD/Enzyme.jl).

```@meta
CurrentModule = NGCSimLib
```

## What it gives you

- **`Compartment`** — typed handle into a flat global-state dict. Reads/writes
  are routed through one mutable singleton; arithmetic auto-unwraps through
  multiple dispatch (no Python-style metaclass).
- **`Component`** — user-defined biophysical unit. Subtype `AbstractComponent`
  directly or use `@ngc_component` for the boilerplate-free version.
- **`@compilable` method bodies** — captured as `Expr` at definition time
  and rewritten by the Parser into pure `(ctx; kwargs...) → ctx` functions
  that Reactant can trace.
- **`Context`** — scope manager with do-block syntax
  (`Context("net") do ctx … end`); auto-registers every Component constructed
  inside it and wires Compartments to their full paths.
- **`MethodProcess` / `JointProcess`** — ordered chains of `@compilable`
  calls; one Julia-eager runner via `compile_process!`, one JIT runner via
  `compile_with_reactant!`. Same SHAPE, swap-in JIT.

## At a glance

```julia
using NGCSimLib

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

NGCSimLib.Context("net") do _ctx
    cell = RateNeuron("layer1", "", Any[], Dict{Symbol,Any}(),
                      NGCSimLib.Compartment([0.0, 0.0, 0.0]))
    NGCSimLib.post_init!(cell)

    process = NGCSimLib.MethodProcess(name="step")
    process >> (cell, :advance!)
    NGCSimLib.post_init!(process)
end

process = NGCSimLib.get_processes(NGCSimLib.get_context("net"))["step"]
NGCSimLib.compile_process!(process)
ctx_out, _ = NGCSimLib.run(process; dt=0.5)
```

For JIT-compiled execution, see [JIT compilation with Reactant](getting_started/jit.md).

## Read next

```@contents
Pages = [
    "getting_started/installation.md",
    "getting_started/quickstart.md",
    "getting_started/jit.md",
    "getting_started/architecture.md",
    "api/index.md",
]
Depth = 2
```

## NGC stack position

| Layer | Package | Status |
|---|---|---|
| 0 (substrate) | **NGCSimLib** (this) | substrate complete; JIT working |
| 1 (zoo) | NGCLearn.jl | scaffold next |
| 2 (PC framework) | FabricPC.jl | later |

Each layer is its own GitHub repo. End-to-end acceptance is verified against
[`ngc-museum`](https://github.com/NACLab/ngc-museum) exhibits.

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
