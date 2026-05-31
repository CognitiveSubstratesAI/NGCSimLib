# NGCSimLib

**Julia port of [NACLab](https://www.cs.rit.edu/~ago/nac_lab.html)'s
[`ngc-sim-lib`](https://github.com/NACLab/ngc-sim-lib).** The substrate layer
of the NGC stack — Component / Compartment / Context / Process — for building
biophysical and neurobiological simulation graphs in Julia.

```@meta
CurrentModule = NGCSimLib
```

## What is NGCSimLib?

NGCSimLib is the simulation substrate that all higher-level NACLab models are
built on. It provides:

- **`Component`** — a user-defined biophysical unit (neuron, synapse, encoder…)
- **`Compartment`** — a piece of mutable state owned by a Component, with
  arithmetic-overloaded so you can write `neuron.v >> synapse.input` to wire
  things together
- **`Context`** — a named scope that holds Components and orchestrates their
  registration into the global state graph
- **`Process`** — a scheduled callable produced by AST-rewriting a Component's
  `@compilable` method into a pure function, JIT-compiled via Reactant.jl

```@contents
Pages = [
    "getting_started/installation.md",
    "getting_started/architecture.md",
    "api/index.md",
]
Depth = 2
```

## NGC stack position

NGCSimLib is Layer 0:

| Layer | Package | Purpose |
|---|---|---|
| 0 (substrate) | **NGCSimLib** (this) | Component / Compartment / Context / Process |
| 1 (model zoo) | NGCLearn.jl | 11+ neuron families, 40+ synapse families, encoders, integrators |
| 2 (PC framework) | FabricPC.jl | Predictive coding graph: nodes, wires, energy minimization, muPC scaling |

Each layer is its own GitHub repo, each can be installed independently.

## Status

**Phase A scaffold** — the package loads, type hierarchy is in place, every
source file exists as a documented stub. Implementation lands incrementally
with acceptance gates per `ngc-museum` exhibit reproduction.

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
