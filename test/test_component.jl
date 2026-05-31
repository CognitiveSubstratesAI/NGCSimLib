# test_component.jl — coverage for src/core/Component.jl

# Define a probe component subtype (manual subtyping, no macro)
mutable struct _ProbeNeuron <: NGCSimLib.AbstractComponent
    name::String
    context_path::String
    args::Vector{Any}
    kwargs::Dict{Symbol, Any}
    voltage::NGCSimLib.Compartment{Vector{Float64}}
    spikes::NGCSimLib.Compartment{Vector{Float64}}
end

@testset "compartments() walks struct fields" begin
    v = NGCSimLib.Compartment(zeros(3))
    s = NGCSimLib.Compartment(zeros(3))
    c = _ProbeNeuron("layer1", "net", Any[], Dict{Symbol, Any}(), v, s)
    cps = NGCSimLib.compartments(c)
    @test length(cps) == 2
    field_names = first.(cps)
    @test :voltage in field_names
    @test :spikes in field_names
    # name + context_path accessors
    @test NGCSimLib.name(c) == "layer1"
    @test NGCSimLib.context_path(c) == "net"
end

@testset "@ngc_component macro injects standard fields + kw constructor" begin
    NGCSimLib.@ngc_component mutable struct _MacroNeuron
        v::NGCSimLib.Compartment{Vector{Float64}}
    end
    @test _MacroNeuron <: NGCSimLib.AbstractComponent
    @test :name in fieldnames(_MacroNeuron)
    @test :context_path in fieldnames(_MacroNeuron)
    @test :args in fieldnames(_MacroNeuron)
    @test :kwargs in fieldnames(_MacroNeuron)
    @test :v in fieldnames(_MacroNeuron)

    # kw constructor — required user field must be given
    @test_throws ErrorException _MacroNeuron(name="x")
    n = _MacroNeuron(name="x", v=NGCSimLib.Compartment([0.0]))
    @test NGCSimLib.name(n) == "x"
    @test NGCSimLib.context_path(n) == ""    # default
    @test length(NGCSimLib.compartments(n)) == 1
end

# Probe methods marked with @compilable. Note: defined at module scope (not
# inside a @testset) so the macro can capture the body at definition time.
NGCSimLib.@compilable function _probe_advance!(c::_ProbeNeuron, dt::Float64)
    NGCSimLib.set!(c.voltage, NGCSimLib.get_value(c.voltage) .+ dt)
    return c
end

@testset "@compilable registers the body Expr and defines the function" begin
    # Eager dispatch still works
    v = NGCSimLib.Compartment([1.0, 2.0])
    s = NGCSimLib.Compartment([0.0, 0.0])
    NGCSimLib.reset_global_state!()
    NGCSimLib.setup!(v, "v", "net.layer")
    NGCSimLib.setup!(s, "s", "net.layer")
    c = _ProbeNeuron("layer", "net", Any[], Dict{Symbol, Any}(), v, s)
    _probe_advance!(c, 0.5)
    @test NGCSimLib.get_value(v) == [1.5, 2.5]

    # Body Expr is registered for later JIT compilation
    @test NGCSimLib.is_compilable_method(_ProbeNeuron, :_probe_advance!)
    body = NGCSimLib.get_compilable_body(_ProbeNeuron, :_probe_advance!)
    @test body isa Expr
    @test body.head === :block
    # Method enumeration
    @test :_probe_advance! in NGCSimLib.compilable_methods(_ProbeNeuron)
end

@testset "is_compilable_method walks supertypes" begin
    # Register a method on the abstract supertype …
    NGCSimLib.@compilable function _abstract_hello(c::NGCSimLib.AbstractComponent)
        return NGCSimLib.name(c)
    end
    # … any concrete subtype should see it via supertype walk.
    @test NGCSimLib.is_compilable_method(_ProbeNeuron, :_abstract_hello)
    body = NGCSimLib.get_compilable_body(_ProbeNeuron, :_abstract_hello)
    @test body isa Expr
end

@testset "get_compilable_body raises on missing" begin
    @test_throws ErrorException NGCSimLib.get_compilable_body(_ProbeNeuron, :no_such_method)
end

@testset "show renders type + name + compartment field names" begin
    v = NGCSimLib.Compartment([0.0])
    s = NGCSimLib.Compartment([0.0])
    c = _ProbeNeuron("hi", "", Any[], Dict{Symbol, Any}(), v, s)
    out = sprint(show, c)
    @test occursin("_ProbeNeuron", out)
    @test occursin("name=\"hi\"", out)
    @test occursin("voltage", out)
    @test occursin("spikes", out)
end
