# Quickstart

A walk-through of building a tiny network with NGCSimLib's substrate.
Working code for every snippet here lives in
[`examples/`](https://github.com/CognitiveSubstratesAI/NGCSimLib/tree/main/examples).

## 1. Define a Component

A Component is a user-defined biophysical unit. The simplest path is to
subtype `AbstractComponent` directly. Every subtype must expose four
protocol fields used by the registration / `@ngc_component` machinery:

```julia
using NGCSimLib

mutable struct RateNeuron <: NGCSimLib.AbstractComponent
    name::String              # user-supplied identifier
    context_path::String      # set by post_init!
    args::Vector{Any}         # captured constructor args (for to_json)
    kwargs::Dict{Symbol,Any}  # captured constructor kwargs
    voltage::NGCSimLib.Compartment   # any field <: AbstractCompartmentLike
end                                  # is auto-discovered as a compartment
```

## 2. Mark a method `@compilable`

`@compilable` captures the method body's `Expr` at definition time. At
compile time, the Parser rewrites compartment accesses
(`c.voltage` → `ctx["net:layer1:voltage"]`) and the result is a pure
function suitable for Reactant tracing.

```julia
NGCSimLib.@compilable function advance!(c::RateNeuron, dt)
    NGCSimLib.set!(c.voltage, NGCSimLib.get_value(c.voltage) .+ dt)
    return c
end
```

Every original positional arg after the receiver becomes a **required
kwarg** in the rewritten signature, so `dt` here lands as `_pure(ctx; dt)`.

## 3. Wire it under a `Context`

A `Context` is a scope manager. Inside the `do` block, the manager's
current path is the Context's path (`"net"`). Calling `post_init!(cell)`
sets up each `Compartment` field under `"<ctx>:<comp>:<field>"` and
registers the Component in the Context's COMPONENT bucket.

```julia
NGCSimLib.Context("net") do _ctx
    cell = RateNeuron("layer1", "", Any[], Dict{Symbol,Any}(),
                      NGCSimLib.Compartment([0.0, 0.0, 0.0]))
    NGCSimLib.post_init!(cell)

    process = NGCSimLib.MethodProcess(name="step")
    process >> (cell, :advance!)
    NGCSimLib.post_init!(process)
end
```

After the `do` block exits, the Context remains in the global registry —
you can look it up with `NGCSimLib.get_context("net")`.

## 4. Compile and run the Process

`compile_process!` walks the method order, calls the Parser on each step,
and produces a `CompiledRunner` wrapping a Julia closure.

```julia
process = NGCSimLib.get_processes(NGCSimLib.get_context("net"))["step"]
NGCSimLib.compile_process!(process)

# Run — kwargs match `keyword_order` and thread through the steps
ctx_out, watched = NGCSimLib.run(process; dt=0.5)
@info ctx_out["net:layer1:voltage"]
# [0.5, 0.5, 0.5]
```

`run` defaults to threading the global-state dict in and writing the
mutated ctx back. Pass `update=false` to skip the write-back, or pass
`state=…` to use an explicit dict.

## 5. Chain multiple steps

`>>` accepts `(component, :method_sym)` tuples. Steps execute in
order, threading `ctx` through:

```julia
process >> (cell, :reset!)      # zero the voltage first
process >> (cell, :advance!)    # then advance twice
process >> (cell, :advance!)
```

The Parser auto-detects every required kwarg across all steps and unions
them into `process.keyword_order`. A single `run(; dt=0.5)` provides
`dt` to every step that needs it.

## Next steps

- [JIT compilation with Reactant](jit.md) — replace the Julia closure
  with a traced `Reactant.@compile`'d runner.
- [Architecture](architecture.md) — the type hierarchy and rewriter
  pipeline.
- [`examples/02_method_process.jl`](https://github.com/CognitiveSubstratesAI/NGCSimLib/blob/main/examples/02_method_process.jl) — runnable version of the
  multi-step network above.
