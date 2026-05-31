# 03_reactant_jit.jl
#
# Same shape as 02_method_process.jl, but the Process runner is JIT-compiled
# via Reactant. Numerically identical output to the eager path; the win is
# fused XLA codegen for GPU / TPU execution and operator-level optimisations.
#
# Concepts covered:
#   - Compartments holding Reactant.ConcreteRArrays (the JIT-traceable form)
#   - compile_with_reactant!(p, sample_ctx, sample_loop_args): traces the
#     eager runner once and replaces p.compiled with a CompiledRunner wrapping
#     Reactant.Compiler.Thunk
#   - subsequent run() calls dispatch through the JIT, not the closure
#
# Validated by decisions.md #9: the Parser's Dict-ctx output is already
# Reactant-traceable as-is — no Parser rewrite required.
#
# Run with: julia --project=. examples/03_reactant_jit.jl

using NGCSimLib
using Reactant

# A minimal component. Compartment field is untyped (or
# `Compartment{<:AbstractArray}`) because Reactant arrays parameterise
# differently from plain Vectors — see decisions.md #9 wart.
mutable struct JITNeuron <: NGCSimLib.AbstractComponent
    name::String
    context_path::String
    args::Vector{Any}
    kwargs::Dict{Symbol,Any}
    voltage::NGCSimLib.Compartment
end

# One @compilable method. After Parser rewrite the signature is
# `_pure_JITNeuron_advance!(ctx; dt)` — every original positional arg
# (after the receiver) is promoted to a required kwarg.
NGCSimLib.@compilable function advance!(c::JITNeuron, dt)
    NGCSimLib.set!(c.voltage, NGCSimLib.get_value(c.voltage) .+ dt)
    return c
end

# Build under a Context, using Reactant arrays for the Compartment values.
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

process = NGCSimLib.get_processes(NGCSimLib.get_context("net"))["step"]

# 1. Eager compile — gives compile_with_reactant! a closure to trace.
NGCSimLib.compile_process!(process)
@info "1. Eager runner ready" runner = process.compiled

# 2. Build sample args matching the shapes/types Reactant should trace against.
sample_ctx       = Dict{String,Any}(
    "net:layer1:voltage" => Reactant.ConcreteRArray([1.0, 2.0, 3.0]),
)
sample_loop_args = Any[Reactant.ConcreteRArray(0.5)]   # dt

# 3. JIT-compile. Replaces process.compiled with a CompiledRunner wrapping
#    Reactant.Compiler.Thunk. First trace ~30-60s; subsequent calls are fast.
NGCSimLib.compile_with_reactant!(process, sample_ctx, sample_loop_args)
@info "2. JIT-compiled" runner = process.compiled

# 4. Run the compiled version. Bit-identical output to the eager path.
ctx_out, _ = NGCSimLib.run(process; dt=Reactant.ConcreteRArray(0.5))
@info "3. JIT result" voltage = Array(ctx_out["net:layer1:voltage"])
# expected: [1.5, 2.5, 3.5]
