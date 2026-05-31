# 02_method_process.jl
#
# Chain @compilable methods through a MethodProcess; run them eagerly.
#
# Concepts covered:
#   - @compilable: marks a method body for Parser rewriting (compartment
#     accesses → ctx-dict reads/writes)
#   - MethodProcess: ordered sequence of (component, method) steps
#   - `>>` operator for chain construction
#   - compile_process!: builds the Julia-eager runner
#   - run(p; kwargs...): executes the runner; threads kwargs as named values
#
# Run with: julia --project=. examples/02_method_process.jl

using NGCSimLib

mutable struct LeakyNeuron <: NGCSimLib.AbstractComponent
    name::String
    context_path::String
    args::Vector{Any}
    kwargs::Dict{Symbol, Any}
    voltage::NGCSimLib.Compartment
end

# A @compilable method: signature is preserved through the Parser, the body
# is rewritten so `c.voltage` becomes `ctx["net:layer1:voltage"]`. After
# rewriting, the function looks like:
#   _pure_LeakyNeuron_advance!(ctx; dt, leak) =
#       (ctx["net:layer1:voltage"] = ctx["net:layer1:voltage"] .* (1 - leak) .+ dt; ctx)
NGCSimLib.@compilable function advance!(c::LeakyNeuron, dt, leak)
    v_new = NGCSimLib.get_value(c.voltage) .* (1.0 - leak) .+ dt
    NGCSimLib.set!(c.voltage, v_new)
    return c
end

# A second @compilable method
NGCSimLib.@compilable function reset!(c::LeakyNeuron)
    NGCSimLib.set!(c.voltage, zeros(3))
    return c
end

# Build under a Context
NGCSimLib.Context("net") do _ctx
    cell = LeakyNeuron(
        "layer1", "", Any[], Dict{Symbol, Any}(),
        NGCSimLib.Compartment([10.0, 10.0, 10.0])
    )
    NGCSimLib.post_init!(cell)

    # Chain steps: reset → advance → advance. `>>` accepts (component, :symbol) tuples.
    process = NGCSimLib.MethodProcess(; name="step")
    process >> (cell, :reset!)
    process >> (cell, :advance!)
    process >> (cell, :advance!)
    NGCSimLib.post_init!(process)
end

# Compile the process — produces a CompiledRunner wrapping a Julia closure.
process = NGCSimLib.get_processes(NGCSimLib.get_context("net"))["step"]
NGCSimLib.compile_process!(process)
@info "process compiled" keyword_order = process.keyword_order

# Run: kwargs are matched against keyword_order, packed into loop_args, threaded
# through the rewritten functions.
ctx_out, _ = NGCSimLib.run(process; dt=0.5, leak=0.1)
@info "after one run" voltage = ctx_out["net:layer1:voltage"]
# Sequence: reset → [0,0,0], advance → [0.5,0.5,0.5], advance → [0.95, 0.95, 0.95]

# Run again — state persists in the global singleton between runs (update=true).
ctx_out, _ = NGCSimLib.run(process; dt=0.5, leak=0.1)
@info "after second run" voltage = ctx_out["net:layer1:voltage"]
# Same trajectory because reset! zeros the slot first each time.

# View the compiled steps
print(NGCSimLib.view_compiled(process))
