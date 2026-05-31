# test_context.jl — coverage for ContextManager.jl + Context.jl + ContextAware.jl

# Probe component for the auto-registration tests (at module scope so the
# struct is visible to multiple testsets without re-eval).
mutable struct _CtxNeuron <: NGCSimLib.AbstractComponent
    name::String
    context_path::String
    args::Vector{Any}
    kwargs::Dict{Symbol,Any}
    voltage::NGCSimLib.Compartment{Vector{Float64}}
    spikes::NGCSimLib.Compartment{Vector{Float64}}
end

_make_neuron(name::String) = _CtxNeuron(
    name, "", Any[], Dict{Symbol,Any}(),
    NGCSimLib.Compartment(zeros(3)),
    NGCSimLib.Compartment(zeros(3)),
)

# ── ContextManager ────────────────────────────────────────────────────────────

@testset "ContextManager singleton + clear" begin
    NGCSimLib.clear_contexts!()
    cm1 = NGCSimLib.context_manager()
    cm2 = NGCSimLib.context_manager()
    @test cm1 === cm2
    @test NGCSimLib.current_path()       == ""
    @test NGCSimLib.current_context()    === nothing
    @test NGCSimLib.current_location()   == ""
end

@testset "path arithmetic: join / split / append" begin
    NGCSimLib.clear_contexts!()
    cm = NGCSimLib.context_manager()
    @test NGCSimLib.join_path(cm, "foo:bar")           == "foo:bar"
    @test NGCSimLib.join_path(cm, ["foo","bar"])       == "foo:bar"
    @test NGCSimLib.split_path(cm, "foo:bar:baz")      == ["foo","bar","baz"]
    @test NGCSimLib.split_path(cm, "")                 == String[]
    @test NGCSimLib.append_path(cm; addition="a")      == "a"     # empty root
    @test NGCSimLib.append_path(cm; root="x", addition="y") == "x:y"
    @test NGCSimLib.append_path(cm; root="x")          == "x"     # no addition
end

@testset "step! / step_back! / step_to! mutate the path" begin
    NGCSimLib.clear_contexts!()
    @test NGCSimLib.current_path() == ""
    NGCSimLib.step!("a"; catch_empty=false)
    @test NGCSimLib.current_path() == "a"
    NGCSimLib.step!("b"; catch_empty=false)
    @test NGCSimLib.current_path() == "a:b"
    @test NGCSimLib.current_location() == "b"
    NGCSimLib.step_back!()
    @test NGCSimLib.current_path() == "a"
    NGCSimLib.step_to!("x:y:z")
    @test NGCSimLib.current_path() == "x:y:z"
    NGCSimLib.step_to!("")
    @test NGCSimLib.current_path() == ""
    @test NGCSimLib.step_back!() == false   # no-op at root
end

# ── Context (idempotency + entry/exit) ────────────────────────────────────────

@testset "Context() is idempotent at the same path" begin
    NGCSimLib.clear_contexts!()
    a = NGCSimLib.Context("world")
    b = NGCSimLib.Context("world")
    @test a === b
    @test a.path == "world"
    @test a.name == "world"
end

@testset "Context do-block enters/exits scope" begin
    NGCSimLib.clear_contexts!()
    inside_path = ""
    NGCSimLib.Context("world") do ctx
        inside_path = NGCSimLib.current_path()
        @test NGCSimLib.current_context() === ctx
    end
    @test inside_path == "world"
    # exited — back to root
    @test NGCSimLib.current_path() == ""
    @test NGCSimLib.current_context() === nothing
    # but the context is still in the global registry
    @test NGCSimLib.get_context("world") !== nothing
end

@testset "Nested Context blocks build a colon-path" begin
    NGCSimLib.clear_contexts!()
    inner_path = ""
    NGCSimLib.Context("world") do _outer
        NGCSimLib.Context("agent") do _inner
            inner_path = NGCSimLib.current_path()
        end
    end
    @test inner_path == "world:agent"
    @test NGCSimLib.get_context("world:agent") !== nothing
end

# ── ContextAware: post_init! pipeline ─────────────────────────────────────────

@testset "post_init! wires compartments + registers in enclosing Context" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()

    cell = nothing
    NGCSimLib.Context("net") do ctx
        cell = _make_neuron("layer1")
        NGCSimLib.post_init!(cell)
        # Inside the block, before exit:
        @test cell.context_path == "net"
        @test cell.voltage.root_target == "net:layer1:voltage"
        @test cell.spikes.root_target  == "net:layer1:spikes"
        # Global state has the keys
        @test NGCSimLib.check_key("net:layer1:voltage")
        @test NGCSimLib.check_key("net:layer1:spikes")
        # Registered in the Context's COMPONENT bucket
        comps = NGCSimLib.get_components(ctx)
        @test haskey(comps, "layer1")
        @test comps["layer1"] === cell
    end
end

@testset "@context_aware macro is equivalent to manual post_init!" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()

    NGCSimLib.Context("net") do ctx
        cell = NGCSimLib.@context_aware _make_neuron("auto1")
        @test cell.context_path        == "net"
        @test cell.voltage.root_target == "net:auto1:voltage"
        @test haskey(NGCSimLib.get_components(ctx), "auto1")
    end
end

@testset "Components built OUTSIDE a Context block don't auto-register" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    cell = _make_neuron("orphan")
    NGCSimLib.post_init!(cell)
    @test cell.context_path == ""    # no active context
    @test cell.voltage.root_target == "orphan:voltage"   # bare name as prefix
    @test cell.spikes.root_target  == "orphan:spikes"
    # No Context was active, so nothing got registered anywhere.
    @test NGCSimLib.current_context() === nothing
end

@testset "add_connection! records dest->source wires on the Context" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()

    NGCSimLib.Context("net") do ctx
        a = _make_neuron("a"); NGCSimLib.post_init!(a)
        b = _make_neuron("b"); NGCSimLib.post_init!(b)
        # Wire a.voltage >> b.voltage  (source >> dest)
        a.voltage >> b.voltage
        # The Context now has a recorded connection
        @test haskey(ctx.connections, b.voltage.root_target)
        @test ctx.connections[b.voltage.root_target] === a.voltage
    end
end

# ── recompile! stub (Phase A: walks, doesn't compile) ─────────────────────────

@testset "recompile! Phase-A walks targets in priority order (no compile! yet)" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    NGCSimLib.Context("net") do ctx
        c = _make_neuron("x"); NGCSimLib.post_init!(c)
        # Should run without error even though `compile!` isn't defined
        NGCSimLib.recompile!(ctx)
        @test true   # if we got here, the walk succeeded
    end
end
