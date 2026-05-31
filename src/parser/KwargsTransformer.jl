# KwargsTransformer.jl — port of ngcsimlib/_src/parser/kwargsTransformer.py
# Spec: docs/specs/04_parser_spec.md §"KwargsTransformer".
#
# Upstream rewrites `kwargs["lr"]` → `lr` and tracks which keys were used so
# the rewritten function signature can declare them as proper kw parameters.
#
# In Julia this is barely needed — kwargs are already named keyword parameters
# at the call site (`f(c, dt=0.5)`), not a dict lookup. The only case this
# would matter is if user code writes `kwargs[:lr]` explicitly, which we
# rewrite to a bare local `lr` for consistency with upstream Phase B output.
#
# Phase A: provide the type + visit() interface so Parser.jl can call it;
# the rewrite itself handles the rare `kwargs[KEY]` pattern. Phase B will
# integrate with the function-signature builder.

"""
    KwargsTransformer

Walks an `Expr`, rewrites `kwargs[KEY]` lookups to bare references, and
tracks every key that was rewritten in `transformed_kwargs`.

Fields:
  - `transformed_kwargs::Set{Symbol}` — every key extracted from a `kwargs[…]` lookup
  - `kwargs_sym::Symbol`              — the parameter name that holds kwargs (default `:kwargs`)
"""
mutable struct KwargsTransformer
    transformed_kwargs::Set{Symbol}
    kwargs_sym::Symbol
end

KwargsTransformer(; kwargs_sym::Symbol=:kwargs) =
    KwargsTransformer(Set{Symbol}(), kwargs_sym)

"""
    visit(t::KwargsTransformer, e) -> Expr | atom

Rewrite `kwargs[:foo]` / `kwargs["foo"]` → `foo`, recording `:foo` in
`transformed_kwargs`. Mirrors upstream `visit_Subscript`
(kwargsTransformer.py:8-15).
"""
function visit(t::KwargsTransformer, e)
    e isa Expr || return e

    # `kwargs[key]` is parsed as `Expr(:ref, :kwargs, key_expr)`
    if e.head === :ref && length(e.args) == 2 && e.args[1] === t.kwargs_sym
        key_expr = e.args[2]
        key_sym = if key_expr isa QuoteNode && key_expr.value isa Symbol
            key_expr.value
        elseif key_expr isa AbstractString
            Symbol(key_expr)
        elseif key_expr isa Symbol
            key_expr
        else
            nothing
        end
        if key_sym !== nothing
            push!(t.transformed_kwargs, key_sym)
            return key_sym
        end
    end

    return Expr(e.head, [visit(t, a) for a in e.args]...)
end

"""
    transform_kwargs(body::Expr; kwargs_sym=:kwargs) -> (rewritten::Expr, keys::Set{Symbol})

Convenience: build a transformer, walk `body`, return `(rewritten, keys)`.
"""
function transform_kwargs(body::Expr; kwargs_sym::Symbol=:kwargs)
    t = KwargsTransformer(; kwargs_sym=kwargs_sym)
    return (visit(t, body), t.transformed_kwargs)
end

export KwargsTransformer, transform_kwargs
