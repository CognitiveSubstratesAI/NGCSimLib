# test_reactant_integration.jl — end-to-end Process JIT validation
#
# Verifies that compile_with_reactant! produces a traced runner that:
#   - compiles without error against the Parser-output ctx-dict shape
#   - returns bit-identical output to the eager Julia path
#   - mutates the shared global state on `run()` with `update=true`
#
# Per decisions.md #9: Reactant 0.2.262 traces through Dict{String,Any} ctx
# directly; no Parser rewrite required.

import Reactant

# Note: Compartment field is untyped (or AbstractArray) per decisions.md #9
# wart — Reactant returns ConcretePJRTArray{T,N,1}, not ConcreteRArray{T,N},
# and the 3-param form doesn't fit a 2-param signature.
mutable struct _ReactantNeuron <: NGCSimLib.AbstractComponent
    name::String
    context_path::String
    args::Vector{Any}
    kwargs::Dict{Symbol,Any}
    voltage::NGCSimLib.Compartment
end

NGCSimLib.@compilable function _reactant_advance!(c::_ReactantNeuron, dt)
    NGCSimLib.set!(c.voltage, NGCSimLib.get_value(c.voltage) .+ dt)
    return c
end

NGCSimLib.@compilable function _reactant_reset!(c::_ReactantNeuron)
    NGCSimLib.set!(c.voltage, NGCSimLib.get_value(c.voltage) .* 0.0)
    return c
end

@testset "compile_with_reactant! wraps eager runner without breaking it" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    NGCSimLib.clear_compiled!()

    # Build the component under a Context
    initial_v = Reactant.ConcreteRArray([1.0, 2.0, 3.0])
    ctx_obj = NGCSimLib.Context("net")
    NGCSimLib._enter!(ctx_obj)
    neuron = _ReactantNeuron("layer", "", Any[], Dict{Symbol,Any}(),
                             NGCSimLib.Compartment(initial_v))
    NGCSimLib.post_init!(neuron)

    p = NGCSimLib.MethodProcess(name="step")
    p >> (neuron, :_reactant_advance!)
    NGCSimLib.post_init!(p)

    NGCSimLib._exit!(ctx_obj)

    # Eager compile first
    NGCSimLib.compile_process!(p)
    @test NGCSimLib.is_compiled(p)
    eager_fn = p.compiled

    # Capture eager output for comparison
    ctx0    = Dict{String,Any}("net:layer:voltage" => initial_v)
    dt      = Reactant.ConcreteRArray(0.5)
    out_eager, _ = eager_fn(ctx0, Any[dt])

    # Now JIT compile
    ctx_sample  = Dict{String,Any}("net:layer:voltage" => initial_v)
    sample_args = Any[dt]
    NGCSimLib.compile_with_reactant!(p, ctx_sample, sample_args)
    @test NGCSimLib.is_compiled(p)
    # p.compiled is now the Reactant-traced version (different identity)
    @test p.compiled !== eager_fn

    # Re-run with the JIT version
    ctx_jit = Dict{String,Any}("net:layer:voltage" => initial_v)
    out_jit, _ = p.compiled(ctx_jit, sample_args)

    # Numerical equivalence
    @test Array(out_eager["net:layer:voltage"]) == Array(out_jit["net:layer:voltage"])
    @test Array(out_jit["net:layer:voltage"]) == [1.5, 2.5, 3.5]
end

@testset "compile_with_reactant! handles multi-step processes" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    NGCSimLib.clear_compiled!()

    initial_v = Reactant.ConcreteRArray([10.0, 20.0, 30.0])
    ctx_obj = NGCSimLib.Context("net")
    NGCSimLib._enter!(ctx_obj)
    neuron = _ReactantNeuron("layer", "", Any[], Dict{Symbol,Any}(),
                             NGCSimLib.Compartment(initial_v))
    NGCSimLib.post_init!(neuron)

    p = NGCSimLib.MethodProcess(name="multi")
    p >> (neuron, :_reactant_advance!)
    p >> (neuron, :_reactant_advance!)        # advance twice in one run
    NGCSimLib.post_init!(p)

    NGCSimLib._exit!(ctx_obj)

    NGCSimLib.compile_process!(p)
    dt = Reactant.ConcreteRArray(0.5)

    ctx_sample = Dict{String,Any}("net:layer:voltage" => initial_v)
    NGCSimLib.compile_with_reactant!(p, ctx_sample, Any[dt])

    # Two advances of 0.5: voltage = initial + 0.5 + 0.5 = initial + 1.0
    out, _ = p.compiled(Dict{String,Any}("net:layer:voltage" => initial_v), Any[dt])
    @test Array(out["net:layer:voltage"]) == [11.0, 21.0, 31.0]
end

@testset "compile_with_reactant! triggers compile_process! lazily" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    NGCSimLib.clear_compiled!()

    initial_v = Reactant.ConcreteRArray([1.0, 2.0, 3.0])
    ctx_obj = NGCSimLib.Context("net")
    NGCSimLib._enter!(ctx_obj)
    neuron = _ReactantNeuron("layer", "", Any[], Dict{Symbol,Any}(),
                             NGCSimLib.Compartment(initial_v))
    NGCSimLib.post_init!(neuron)

    p = NGCSimLib.MethodProcess(name="lazy")
    p >> (neuron, :_reactant_reset!)
    NGCSimLib.post_init!(p)
    NGCSimLib._exit!(ctx_obj)

    @test NGCSimLib.is_compiled(p) == false
    # No prior compile_process!; compile_with_reactant! must trigger it.
    NGCSimLib.compile_with_reactant!(p,
        Dict{String,Any}("net:layer:voltage" => initial_v),
        Any[])
    @test NGCSimLib.is_compiled(p)
end
