# NGCSimLib

[![CI](https://github.com/CognitiveSubstratesAI/NGCSimLib/actions/workflows/CI.yml/badge.svg)](https://github.com/CognitiveSubstratesAI/NGCSimLib/actions/workflows/CI.yml)
[![Docs (stable)](https://img.shields.io/badge/docs-stable-blue.svg)](https://cognitivesubstratesai.github.io/NGCSimLib/stable/)
[![Docs (dev)](https://img.shields.io/badge/docs-dev-blue.svg)](https://cognitivesubstratesai.github.io/NGCSimLib/dev/)
[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)
[![Code Style: Blue](https://img.shields.io/badge/code%20style-blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://img.shields.io/badge/ColPrac-Contributor's%20Guide-blueviolet)](https://github.com/SciML/ColPrac)
[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg)](https://opensource.org/licenses/BSD-3-Clause)

**Julia port of [NACLab](https://www.cs.rit.edu/~ago/nac_lab.html)'s
[`ngc-sim-lib`](https://github.com/NACLab/ngc-sim-lib).** The substrate layer
(Component / Compartment / Context / Process) for biophysical / neurobiological
simulation graphs. JIT compilation via [Reactant.jl](https://github.com/EnzymeAD/Reactant.jl);
automatic differentiation via [Enzyme.jl](https://github.com/EnzymeAD/Enzyme.jl).

This is **Layer 0** of the NGC stack:

| Layer | Package | Status | Maps to upstream |
|---|---|---|---|
| 0 (substrate) | **NGCSimLib** (this) | Phase A scaffold | [ngc-sim-lib](https://github.com/NACLab/ngc-sim-lib) (~2.9k LOC) |
| 1 (zoo) | NGCLearn | next | [ngc-learn](https://github.com/NACLab/ngc-learn) (~18.7k LOC) |
| 2 (PC framework) | FabricPC | later | [FabricPC](https://github.com/trueagi-io/FabricPC) (~9.5k LOC) |

Acceptance verified against [ngc-museum](https://github.com/NACLab/ngc-museum)
exhibits — exhibit-by-exhibit reproduction is the gate for "phase done."

## Status

**Phase A scaffold.** Module loads, abstract type hierarchy is in place, every
source file exists as a documented stub. Next: implement support layer + core
types end-to-end.

See [`docs/NGCSimLib_design.md`](docs/NGCSimLib_design.md) for the architecture
and [`docs/specs/`](docs/specs/) for the per-module ports from upstream Python.

## Installation

```julia
# Julia 1.10+
using Pkg
Pkg.add(url = "https://github.com/CognitiveSubstratesAI/NGCSimLib")
```

## Documentation

- [Stable docs](https://cognitivesubstratesai.github.io/NGCSimLib/stable/)
- [Dev docs](https://cognitivesubstratesai.github.io/NGCSimLib/dev/)

## Quick example

(Phase A scaffold — real example arrives with implementation.)

```julia
using NGCSimLib
@info "NGCSimLib version $(NGCSimLib.NGCSIMLIB_VERSION)"
```

## Contributing

This project follows [ColPrac](https://github.com/SciML/ColPrac).
Code style is [Blue](https://github.com/invenia/BlueStyle); run
`julia --project=. -e 'using JuliaFormatter; format(".")'` before submitting.

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
