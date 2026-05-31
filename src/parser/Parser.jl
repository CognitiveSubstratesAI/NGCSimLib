# Parser.jl — port of ngcsimlib/_src/parser/utils.py
# Spec: docs/specs/04_parser_spec.md §"utils.py".
#
# Orchestrates the rewrite from a captured @compilable method body Expr
# into a pure function suitable for Reactant tracing:
#
#   @compilable function advance!(c::MyCell, dt)
#       set!(c.voltage, get_value(c.voltage) + dt)
#       return c
#   end
#
# becomes (after parse_method):
#
#   function _MyCell_advance_pure(ctx::Dict, dt)
#       ctx["net:layer:voltage"] = ctx["net:layer:voltage"] + dt
#       return ctx
#   end
#
# The Julia port is much simpler than the upstream Python:
#   - upstream uses `inspect.getsource` + `ast.parse` to recover the source,
#     then `compile()` + `exec()` to install the rewritten function
#   - we capture the body Expr at @compilable definition time via QuoteNode,
#     and use `Core.eval(Main, …)` to install the rewritten function
#
# Phase A scope:
#   - parse_method(instance, method_sym) → CompiledMethod
#   - compile_object!(c) walks all compilable methods + parses them
#   - CompiledMethod stores the artefact bundle + provides __call__
#
# Phase B will add:
#   - Sub-method inlining (`_sub_parse` recursion)
#   - Sub-Component recursion (`ContextAwareObjectMeta` branch)
#   - Reactant.@compile integration

# ── CompiledMethod ────────────────────────────────────────────────────────────

"""
    CompiledMethod

Bundle holding the parsed/rewritten artefacts for one `@compilable` method:

  - `fn::Function`       — the compiled pure function (callable directly)
  - `fn_expr::Expr`      — the rewritten function definition Expr
  - `auxiliary::Vector{Expr}` — inlined sub-method definitions (Phase B; empty in A)
  - `needed_keys::Set{String}` — every compartment key the body reads/writes
  - `transformed_kwargs::Set{Symbol}` — every kwargs key the body referenced

`CompiledMethod` is callable: `cm(ctx, args...; kwargs...)` invokes `cm.fn`.
"""
struct CompiledMethod
    fn::Function
    fn_expr::Expr
    auxiliary::Vector{Expr}
    needed_keys::Set{String}
    transformed_kwargs::Set{Symbol}
end

(cm::CompiledMethod)(args...; kwargs...) = cm.fn(args...; kwargs...)

# Pretty-printed source. Mirrors upstream `CompiledMethod.code` property.
function code(cm::CompiledMethod)
    buf = IOBuffer()
    for aux in reverse(cm.auxiliary)
        println(buf, aux)
        println(buf)
    end
    print(buf, cm.fn_expr)
    return String(take!(buf))
end

Base.show(io::IO, cm::CompiledMethod) =
    print(io, "CompiledMethod(needed_keys=", length(cm.needed_keys),
          ", aux=", length(cm.auxiliary), ")")

# ── parse_method ──────────────────────────────────────────────────────────────

"""
    parse_method(instance::AbstractComponent, method_name::Symbol;
                 ctx_sym::Symbol=:ctx, kwargs_sym::Symbol=:kwargs) -> CompiledMethod

Take the body Expr registered by `@compilable` for `(typeof(instance), method_name)`,
rewrite it via `ContextTransformer` (compartment access → ctx-dict access)
and `KwargsTransformer` (kwargs subscripts → bare locals), then wrap into a
freshly evaluated function. Returns the `CompiledMethod` bundle.

Mirrors upstream `parse_method` (utils.py:88-113) but skips the recursion
into sub-methods / sub-Components for Phase A scope.
"""
function parse_method(instance::AbstractComponent, method_name::Symbol;
                      ctx_sym::Symbol=:ctx,
                      kwargs_sym::Symbol=:kwargs)
    entry = get_compilable_entry(typeof(instance), method_name)
    original_args = entry.args        # Vector{Any}: [receiver, arg2, arg3, ...]
    body          = entry.body

    # Phase 1: rewrite compartment access in the body.
    ct = ContextTransformer(instance; ctx_sym=ctx_sym, sub_method=false)
    body_rewritten = visit(ct, body)

    # Append `return ctx` if the body doesn't end with one. Spec
    # contextTransformer.py:57-58 — top-level FunctionDef gets `return ctx`
    # synthesized at the tail.
    if !(body_rewritten isa Expr && body_rewritten.head === :block)
        body_rewritten = Expr(:block, body_rewritten)
    end
    if isempty(body_rewritten.args) ||
       !(_is_return_of(last(body_rewritten.args), ctx_sym))
        push!(body_rewritten.args, :(return $ctx_sym))
    end

    # Phase 2: kwargs subscript rewrite.
    body_rewritten2, kwarg_keys = transform_kwargs(body_rewritten; kwargs_sym=kwargs_sym)

    # Synthesize a function definition. The user's original signature was
    # `method_name(receiver, args...; kwargs...)` — we replace the receiver
    # with `ctx` and keep the rest verbatim. Type annotations and defaults
    # carry over for free since we splat the original `Expr`s.
    fn_name = Symbol("_pure_", nameof(typeof(instance)), "_", method_name)
    rewritten_args = Any[ctx_sym]
    # original_args[1] is the receiver (e.g. `:(c::MyType)`); skip it.
    # original_args[2:end] may include a `:parameters` block (kwargs); pass through.
    for a in @view original_args[2:end]
        push!(rewritten_args, a)
    end
    fn_expr = Expr(:function,
        Expr(:call, fn_name, rewritten_args...),
        body_rewritten2,
    )

    # Eval the function in Main so it's reachable; capture the Function value.
    fn_val = Core.eval(Main, fn_expr)

    return CompiledMethod(
        fn_val,
        fn_expr,
        Expr[],
        copy(ct.needed_keys),
        kwarg_keys,
    )
end

# Helper: detect a `return <ctx_sym>` tail.
function _is_return_of(node, ctx_sym::Symbol)
    node isa Expr || return false
    node.head === :return || return false
    length(node.args) == 1 || return false
    node.args[1] === ctx_sym
end

# ── compile_object! ───────────────────────────────────────────────────────────

# Per-instance cache of CompiledMethod bundles. Keyed by (objectid, method_sym)
# so two instances of the same type compile independently.
const _COMPILED_METHODS = IdDict{Any,Dict{Symbol,CompiledMethod}}()

"""
    compile_object!(c::AbstractComponent) -> Dict{Symbol,CompiledMethod}

Walk every `@compilable` method registered for `typeof(c)` and parse each
into a `CompiledMethod`. Stores the bundle in a per-instance cache and
returns it.

Mirrors upstream `compileObject` (utils.py:136-157). Phase A skips
sub-Component recursion (no `ContextAwareObjectMeta` branch yet).
"""
function compile_object!(c::AbstractComponent)
    methods_for_type = compilable_methods(typeof(c))
    bundle = Dict{Symbol,CompiledMethod}()
    for m in methods_for_type
        bundle[m] = parse_method(c, m)
    end
    _COMPILED_METHODS[c] = bundle
    return bundle
end

"""
    get_compiled(c::AbstractComponent, method_name::Symbol) -> CompiledMethod

Look up the parsed `CompiledMethod` for `(c, method_name)`. Calls
`compile_object!(c)` lazily if no bundle exists yet.
"""
function get_compiled(c::AbstractComponent, method_name::Symbol)
    bundle = get!(() -> compile_object!(c), _COMPILED_METHODS, c)
    haskey(bundle, method_name) ||
        ngc_error("no compiled method `", method_name, "` for ", typeof(c))
    return bundle[method_name]
end

"""
    clear_compiled!()

Clear the per-instance compiled-method cache. Test/dev helper; useful
between independent test sets so cached entries from earlier instances
don't shadow.
"""
clear_compiled!() = (empty!(_COMPILED_METHODS); nothing)

export CompiledMethod, parse_method, compile_object!, get_compiled,
       clear_compiled!, code
