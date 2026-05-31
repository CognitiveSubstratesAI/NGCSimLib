# JIT compilation with Reactant

NGCSimLib's substrate is designed so that the **shape** of a compiled
`MethodProcess` matches what [Reactant.jl](https://github.com/EnzymeAD/Reactant.jl)
expects: a pure function `(ctx::Dict, loop_args::Vector) → (ctx, watched)`.
That means switching from an eager Julia runner to a JIT-traced runner is
**one function call** — no Parser rewrite, no Compartment refactor.

Validated empirically: see [`docs/decisions.md`](https://github.com/CognitiveSubstratesAI/NGCSimLib/blob/main/docs/decisions.md) §9.

## What changes vs eager

| | Eager (`compile_process!`) | JIT (`compile_with_reactant!`) |
|---|---|---|
| Backend | Julia (sequential closure) | Reactant (XLA / StableHLO via MLIR) |
| Trace cost | none | once at JIT-compile time (~30-60s first call) |
| Per-call cost | Julia dispatch overhead | XLA kernel execution |
| Compartment values | any Julia values | `Reactant.ConcreteRArray` for traced fields |
| Type info | full | shape-specialized at trace time |
| When to use | development, debugging | hot loops, GPU/TPU targets |

You can **always** start eager and add JIT later. The numeric output is
bit-identical (verified by the integration test suite).

## End-to-end example

```julia
using NGCSimLib
using Reactant

mutable struct JITNeuron <: NGCSimLib.AbstractComponent
    name::String
    context_path::String
    args::Vector{Any}
    kwargs::Dict{Symbol,Any}
    voltage::NGCSimLib.Compartment   # untyped — see note below
end

NGCSimLib.@compilable function advance!(c::JITNeuron, dt)
    NGCSimLib.set!(c.voltage, NGCSimLib.get_value(c.voltage) .+ dt)
    return c
end
```

Build the model with **Reactant arrays** for the compartment values:

```julia
NGCSimLib.Context("net") do _ctx
    cell = JITNeuron(
        "layer1", "", Any[], Dict{Symbol,Any}(),
        NGCSimLib.Compartment(Reactant.ConcreteRArray([1.0, 2.0, 3.0])),
    )
    NGCSimLib.post_init!(cell)

    process = NGCSimLib.MethodProcess(name="step")
    process >> (cell, :advance!)
    NGCSimLib.post_init!(process)
end
```

Then compile eagerly first (gives `compile_with_reactant!` something to
trace), then JIT-compile:

```julia
process = NGCSimLib.get_processes(NGCSimLib.get_context("net"))["step"]

# 1. Eager closure (works without Reactant)
NGCSimLib.compile_process!(process)

# 2. Sample inputs determine the shapes/types Reactant traces against
sample_ctx       = Dict{String,Any}(
    "net:layer1:voltage" => Reactant.ConcreteRArray([1.0, 2.0, 3.0]),
)
sample_loop_args = Any[Reactant.ConcreteRArray(0.5)]  # one Reactant scalar for dt

# 3. JIT — replaces process.compiled with a Reactant.Compiler.Thunk wrapped
#    in a CompiledRunner
NGCSimLib.compile_with_reactant!(process, sample_ctx, sample_loop_args)

# 4. Run — every subsequent run() call dispatches through the JIT
ctx_out, _ = NGCSimLib.run(process; dt=Reactant.ConcreteRArray(0.5))
Array(ctx_out["net:layer1:voltage"])  # [1.5, 2.5, 3.5]
```

## How it works under the hood

`compile_with_reactant!` does three things:

1. Calls `compile_process!` if it hasn't run yet (so the eager closure exists).
2. Calls `Reactant.@compile eager_runner(sample_ctx, sample_loop_args)` —
   Reactant 0.2 traces through the `Dict{String,Any}` ctx with string keys
   as compile-time constants, specializing on the concrete Dict layout it
   sees on first call.
3. Wraps the resulting `Reactant.Compiler.Thunk` in a `CompiledRunner`
   (the opaque-callable wrapper used for both the eager and JIT paths)
   and replaces `process.compiled`.

`run()` is unchanged — `CompiledRunner` dispatches through `payload(...)`
regardless of whether `payload` is a Julia closure or a Reactant Thunk.

## Gotchas

### Compartment field types

When holding Reactant arrays in a Compartment, **leave the Compartment field
untyped or use `Compartment{<:AbstractArray}`**. Don't write
`Compartment{Reactant.ConcreteRArray{Float64,1}}` — `ConcreteRArray` is an
alias for `ConcretePJRTArray{T,N,1}`, and the 2-param signature won't match.
See `docs/decisions.md` §9.

```julia
# OK
voltage::NGCSimLib.Compartment

# OK
voltage::NGCSimLib.Compartment{<:AbstractArray}

# NOT OK — type mismatch on construction
voltage::NGCSimLib.Compartment{Reactant.ConcreteRArray{Float64,1}}
```

### Shape stability

Reactant traces against the concrete shapes/types of the sample inputs.
Subsequent calls with different shapes will error. To recompile against
new shapes, re-run `compile_process!(p)` (reverts to eager), then
`compile_with_reactant!(p, new_samples...)`.

### First-trace latency

The first `compile_with_reactant!` call traces through Reactant's full
MLIR/XLA pipeline — expect ~30-60s on a CPU backend the first time.
Subsequent runs hit the cached XLA kernel and are fast.

## See also

- [`examples/03_reactant_jit.jl`](https://github.com/CognitiveSubstratesAI/NGCSimLib/blob/main/examples/03_reactant_jit.jl) — runnable version of the above.
- [`docs/decisions.md`](https://github.com/CognitiveSubstratesAI/NGCSimLib/blob/main/docs/decisions.md) §9 — empirical validation that Parser
  output traces through Reactant without modification.
- [Reactant.jl docs](https://enzymead.github.io/Reactant.jl/stable/) — the
  full tracing / compilation API.
