# test_parser.jl — coverage for src/parser/*

# Probe component at module scope so @compilable macros can capture body Exprs.
mutable struct _ParserNeuron <: NGCSimLib.AbstractComponent
    name::String
    context_path::String
    args::Vector{Any}
    kwargs::Dict{Symbol, Any}
    voltage::NGCSimLib.Compartment{Vector{Float64}}
    spikes::NGCSimLib.Compartment{Vector{Float64}}
end

_make_parser_neuron(name::String) = _ParserNeuron(
    name, "", Any[], Dict{Symbol, Any}(),
    NGCSimLib.Compartment(zeros(3)),
    NGCSimLib.Compartment(zeros(3))
)

# Register two @compilable methods on _ParserNeuron — body Exprs captured here.
NGCSimLib.@compilable function _parser_advance!(c::_ParserNeuron, dt::Float64)
    NGCSimLib.set!(c.voltage, NGCSimLib.get_value(c.voltage) .+ dt)
    return c
end

NGCSimLib.@compilable function _parser_reset!(c::_ParserNeuron)
    NGCSimLib.set!(c.voltage, zeros(3))
    NGCSimLib.set!(c.spikes, zeros(3))
    return c
end

# ── ContextTransformer ────────────────────────────────────────────────────────

@testset "_resolve_field_chain resolves c.field on instance" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    c = _make_parser_neuron("p")
    NGCSimLib.post_init!(c)   # gives compartments their root_targets

    t = NGCSimLib.ContextTransformer(c)
    comp = NGCSimLib._resolve_field_chain(c, :(c.voltage))
    @test comp === c.voltage
    @test comp.root_target == "p:voltage"

    # Non-compartment field resolves to nothing
    @test NGCSimLib._resolve_field_chain(c, :(c.name)) === nothing
end

@testset "ContextTransformer rewrites c.field → ctx[key]" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    c = _make_parser_neuron("p")
    NGCSimLib.post_init!(c)

    t = NGCSimLib.ContextTransformer(c)
    rewritten = NGCSimLib.visit(t, :(c.voltage))
    @test rewritten == :(ctx["p:voltage"])
    @test "p:voltage" in t.needed_keys
end

@testset "ContextTransformer rewrites set!(c.field, v)" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    c = _make_parser_neuron("p")
    NGCSimLib.post_init!(c)

    t = NGCSimLib.ContextTransformer(c)
    rewritten = NGCSimLib.visit(t, :(NGCSimLib.set!(c.voltage, [1.0, 2.0, 3.0])))
    @test rewritten == :(ctx["p:voltage"] = [1.0, 2.0, 3.0])
end

@testset "ContextTransformer rewrites get_value(c.field)" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    c = _make_parser_neuron("p")
    NGCSimLib.post_init!(c)

    t = NGCSimLib.ContextTransformer(c)
    rewritten = NGCSimLib.visit(t, :(NGCSimLib.get_value(c.voltage)))
    @test rewritten == :(ctx["p:voltage"])
end

@testset "ContextTransformer drops `return c` → `return ctx`" begin
    NGCSimLib.clear_contexts!()
    c = _make_parser_neuron("p")
    NGCSimLib.post_init!(c)
    t = NGCSimLib.ContextTransformer(c)
    rewritten = NGCSimLib.visit(t, :(return c))
    @test rewritten == :(return ctx)
end

# ── Scalar hyperparameter inlining ────────────────────────────────────────────
# A component with both Compartment fields AND scalar hyperparameters
# (tau_m, is_stateful, ...). The Parser must rewrite Compartment access to
# ctx[key] AND inline scalar fields as trace-time literals — leaving the
# rewritten function `c`-free so it can be invoked with only `ctx` + kwargs.

mutable struct _ScalarHyperNeuron <: NGCSimLib.AbstractComponent
    name::String
    context_path::String
    args::Vector{Any}
    kwargs::Dict{Symbol, Any}
    # Scalar hyperparameters (NOT compartments)
    tau_m::Float64
    is_stateful::Bool
    label::String
    fx::Function
    # Compartments
    voltage::NGCSimLib.Compartment{Vector{Float64}}
end

_make_scalar_neuron(name::String) = _ScalarHyperNeuron(
    name, "", Any[], Dict{Symbol, Any}(),
    7.5,                            # tau_m
    true,                           # is_stateful
    "alpha",                        # label
    (x) -> x .* 2.0,                # fx
    NGCSimLib.Compartment([0.0, 0.0, 0.0])
)

@testset "ContextTransformer inlines scalar hyperparameter access" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    c = _make_scalar_neuron("p")
    NGCSimLib.post_init!(c)

    t = NGCSimLib.ContextTransformer(c)
    # Numeric scalar: inlined verbatim as a literal node.
    @test NGCSimLib.visit(t, :(c.tau_m)) == 7.5
    # Boolean: same — embedded as literal.
    @test NGCSimLib.visit(t, :(c.is_stateful)) == true
    # String: same.
    @test NGCSimLib.visit(t, :(c.label)) == "alpha"
    # Function: same — the rewritten Expr now has a function-value literal.
    fx_inlined = NGCSimLib.visit(t, :(c.fx))
    @test fx_inlined isa Function
    @test fx_inlined([1.0, 2.0]) == [2.0, 4.0]
end

@testset "ContextTransformer: scalar inline AND Compartment rewrite coexist" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    c = _make_scalar_neuron("p")
    NGCSimLib.post_init!(c)

    t = NGCSimLib.ContextTransformer(c)
    # Mixed expression: voltage compartment + tau_m scalar in one binop.
    # The rewrite must turn each leaf appropriately.
    rewritten = NGCSimLib.visit(t, :(c.voltage .+ c.tau_m))
    @test rewritten == :(ctx["p:voltage"] .+ 7.5)
    @test "p:voltage" in t.needed_keys
end

@testset "ContextTransformer leaves unresolved chains alone (module access)" begin
    NGCSimLib.clear_contexts!()
    c = _make_scalar_neuron("p")
    NGCSimLib.post_init!(c)
    t = NGCSimLib.ContextTransformer(c)
    # `NGCSimLib.set!` — the head `NGCSimLib` is NOT a field of `c`, so the
    # chain is unresolvable on the instance. Must pass through unchanged.
    rewritten = NGCSimLib.visit(t, :(NGCSimLib.set!))
    @test rewritten == :(NGCSimLib.set!)
end

@testset "parse_method end-to-end with scalar fields in body" begin
    # Define a @compilable method that REFERENCES a scalar hyperparameter.
    # Before the fix, the rewritten function dangled with a bare `c.tau_m`.
    # After the fix, `c.tau_m` is inlined and the function runs with only ctx.
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    NGCSimLib.clear_compiled!()

    NGCSimLib.@compilable function _scalar_advance!(c::_ScalarHyperNeuron, dt)
        # Body uses BOTH compartment access AND scalar field access.
        NGCSimLib.set!(c.voltage,
            NGCSimLib.get_value(c.voltage) .+ dt ./ c.tau_m)
        return c
    end

    c = _make_scalar_neuron("p")
    NGCSimLib.post_init!(c)
    cm = NGCSimLib.parse_method(c, :_scalar_advance!)
    @test cm isa NGCSimLib.CompiledMethod

    # The compiled function should run successfully — the rewritten body
    # references neither `c` nor `c.tau_m` (the latter was inlined as 7.5).
    ctx = Dict{String, Any}("p:voltage" => [10.0, 20.0, 30.0])
    out = cm(ctx; dt=1.5)
    # dz = dt / tau_m = 1.5 / 7.5 = 0.2  →  ctx["p:voltage"] .+= 0.2
    @test out["p:voltage"] ≈ [10.2, 20.2, 30.2]
end

# ── KwargsTransformer ─────────────────────────────────────────────────────────

@testset "KwargsTransformer rewrites kwargs[KEY] → KEY" begin
    rewritten, keys = NGCSimLib.transform_kwargs(quote
        x = kwargs[:lr] * y
        z = kwargs[:beta]
    end)
    @test :lr in keys
    @test :beta in keys
    # The rewritten body should contain bare `lr` and `beta`, not `kwargs[…]`.
    src = string(rewritten)
    @test occursin("lr", src)
    @test occursin("beta", src)
    @test !occursin("kwargs[", src)
end

@testset "KwargsTransformer ignores non-kwargs subscripts" begin
    rewritten, keys = NGCSimLib.transform_kwargs(:(arr[3] + other_dict["key"]))
    @test isempty(keys)
    # Subscript on `arr` / `other_dict` is preserved.
    src = string(rewritten)
    @test occursin("arr[3]", src)
    @test occursin("other_dict", src)
end

# ── parse_method / compile_object! end-to-end ─────────────────────────────────

@testset "parse_method produces a callable pure function" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    NGCSimLib.clear_compiled!()
    c = _make_parser_neuron("p")
    NGCSimLib.post_init!(c)

    cm = NGCSimLib.parse_method(c, :_parser_advance!)
    @test cm isa NGCSimLib.CompiledMethod
    @test "p:voltage" in cm.needed_keys

    # Build a ctx dict pre-loaded with the current state and call the pure fn.
    # The Parser promotes all original positional args (after the receiver) to
    # required kwargs, so `dt` comes in via the kwargs-only path.
    ctx = Dict{String, Any}(
        "p:voltage" => [1.0, 2.0, 3.0],
        "p:spikes" => [0.0, 0.0, 0.0]
    )
    out = cm(ctx; dt=0.5)
    @test out === ctx                       # mutates + returns same dict
    @test ctx["p:voltage"] == [1.5, 2.5, 3.5]
end

@testset "compile_object! parses every @compilable method on the type" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    NGCSimLib.clear_compiled!()
    c = _make_parser_neuron("p")
    NGCSimLib.post_init!(c)

    bundle = NGCSimLib.compile_object!(c)
    @test :_parser_advance! in keys(bundle)
    @test :_parser_reset! in keys(bundle)
    @test bundle[:_parser_advance!] isa NGCSimLib.CompiledMethod
    @test bundle[:_parser_reset!] isa NGCSimLib.CompiledMethod

    # The reset method should rewrite TWO set!s — both keys present.
    @test "p:voltage" in bundle[:_parser_reset!].needed_keys
    @test "p:spikes" in bundle[:_parser_reset!].needed_keys
end

@testset "get_compiled lazily compiles on first access" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    NGCSimLib.clear_compiled!()
    c = _make_parser_neuron("p")
    NGCSimLib.post_init!(c)

    # No prior compile_object! call — get_compiled should trigger it.
    cm = NGCSimLib.get_compiled(c, :_parser_advance!)
    @test cm isa NGCSimLib.CompiledMethod

    # Second call returns the same cached instance
    cm2 = NGCSimLib.get_compiled(c, :_parser_advance!)
    @test cm === cm2
end

@testset "get_compiled raises for unknown methods" begin
    NGCSimLib.clear_contexts!()
    c = _make_parser_neuron("p")
    NGCSimLib.post_init!(c)
    @test_throws ErrorException NGCSimLib.get_compiled(c, :no_such_method)
end

@testset "code(cm) prints the rewritten function source" begin
    NGCSimLib.clear_contexts!()
    NGCSimLib.reset_global_state!()
    NGCSimLib.clear_compiled!()
    c = _make_parser_neuron("p")
    NGCSimLib.post_init!(c)
    cm = NGCSimLib.parse_method(c, :_parser_advance!)
    src = NGCSimLib.code(cm)
    @test occursin("ctx", src)
    @test occursin("p:voltage", src)
end
