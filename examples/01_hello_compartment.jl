# 01_hello_compartment.jl
#
# The smallest meaningful NGCSimLib program: define a Component, wire it under
# a Context, read/write its Compartment.
#
# Concepts covered:
#   - subtyping AbstractComponent with the required protocol fields
#   - Compartment construction + setup (via Context + post_init!)
#   - reading values (get_value) and writing them (set!)
#   - the global-state key format: "<context>:<component>:<compartment>"
#
# Run with: julia --project=. examples/01_hello_compartment.jl

using NGCSimLib

# A component holding one Compartment. Every AbstractComponent subtype must
# expose `name`, `context_path`, `args`, `kwargs` (protocol fields used by
# the registration / @ngc_component machinery). Any additional fields whose
# values subtype AbstractCompartmentLike are auto-discovered as compartments.
mutable struct ToyNeuron <: NGCSimLib.AbstractComponent
    name::String
    context_path::String
    args::Vector{Any}
    kwargs::Dict{Symbol,Any}
    voltage::NGCSimLib.Compartment
end

# Build the model under a Context. The `do` block enters the scope; inside,
# `post_init!(cell)` triggers two things:
#   1. each Compartment field of `cell` is set up with key "<ctx>:<comp>:<field>"
#   2. `cell` is registered in the enclosing Context under the COMPONENT bucket
NGCSimLib.Context("net") do _ctx
    cell = ToyNeuron(
        "layer1",                              # name
        "",                                    # context_path (filled by post_init!)
        Any[], Dict{Symbol,Any}(),             # args/kwargs (protocol)
        NGCSimLib.Compartment([0.0, 0.0, 0.0]),
    )
    NGCSimLib.post_init!(cell)

    # The compartment's canonical key:
    @info "compartment key" key = NGCSimLib.root(cell.voltage)

    # Read the initial value
    @info "initial voltage" v = NGCSimLib.get_value(cell.voltage)

    # Mutate via set!. Writes go through the global-state singleton.
    NGCSimLib.set!(cell.voltage, [1.0, 2.0, 3.0])
    @info "after set!" v = NGCSimLib.get_value(cell.voltage)
end

# After the do-block exits, the Context is no longer the "current" scope,
# but it remains registered in the global ContextManager.
ctx_obj = NGCSimLib.get_context("net")
@info "context still registered" path = ctx_obj.path components = length(NGCSimLib.get_components(ctx_obj))

# The global-state singleton retains the values written:
@info "global state retains the key" v = NGCSimLib.from_global_key("net:layer1:voltage")
