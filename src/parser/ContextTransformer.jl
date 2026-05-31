# ContextTransformer.jl — port of ngcsimlib/_src/parser/contextTransformer.py
# Spec: docs/specs/04_parser_spec.md §"ContextTransformer".
#
# Walks a captured method-body `Expr` and rewrites OO-style compartment
# access into pure ctx-dict access:
#
#   c.voltage                       →   ctx["net:layer:voltage"]
#   set!(c.voltage, v)              →   ctx["net:layer:voltage"] = v
#   get_value(c.voltage)            →   ctx["net:layer:voltage"]
#   return c                        →   return ctx   (only at top level)
#
# Compartment access detection happens via runtime introspection of the
# component instance — the transformer needs the instance to know which
# field-access paths resolve to Compartments. (Upstream uses `getattr` walks
# in `visit_Attribute`; we use `hasproperty`/`getproperty`.)
#
# Phase A scope: the four rewrites above + nested `c.subcomponent.field`
# walks. Phase B: nested Component recursion, sub-method inlining,
# Reactant-trace integration.

# ── Helper: resolve a chain like `c.field` or `c.sub.field` on the instance ──

"""
    _resolve_field_chain(instance, head::Expr) -> Union{Compartment, Nothing}

Given a receiver instance and an `Expr` of the form `recv.a.b.c…`, walk
the chain on the instance and return the resolved Compartment, or
`nothing` if any step fails or the leaf isn't a Compartment.

Used by the transformer to decide whether a `getproperty` chain should be
rewritten to a `ctx[key]` read.
"""
function _resolve_field_chain(instance, head::Expr)
    head.head === :. || return nothing
    # Linearise the chain into innermost-first field path:
    # `:(c.a.b.c)` is `Expr(:., Expr(:., Expr(:., :c, :(:a)), :(:b)), :(:c))`.
    # We descend, collecting fields, until we hit the root Symbol.
    path = Symbol[]
    cur = head
    while cur isa Expr && cur.head === :.
        length(cur.args) == 2 || return nothing
        field = cur.args[2]
        f = if field isa QuoteNode
            field.value
        elseif field isa Symbol
            field
        else
            nothing
        end
        f === nothing && return nothing
        push!(path, f)
        cur = cur.args[1]
    end
    cur isa Symbol || return nothing
    # Walk in reverse (outer-most field first since we appended inner-first).
    reverse!(path)
    val = instance
    for f in path
        hasproperty(val, f) || return nothing
        val = getproperty(val, f)
    end
    val isa Compartment ? val : nothing
end

# ── The transformer ──────────────────────────────────────────────────────────

"""
    ContextTransformer

Carries state during a single method-body rewrite.

Fields:
  - `instance::Any`          — the live Component instance (for field-resolution)
  - `ctx_sym::Symbol`        — name of the ctx-dict parameter in the rewritten signature
  - `needed_keys::Set{String}` — every compartment root_target referenced
  - `sub_method::Bool`       — true when transforming an inlined sub-method (Phase B)
"""
mutable struct ContextTransformer
    instance::Any
    ctx_sym::Symbol
    needed_keys::Set{String}
    sub_method::Bool
end

ContextTransformer(instance; ctx_sym::Symbol=:ctx, sub_method::Bool=false) =
    ContextTransformer(instance, ctx_sym, Set{String}(), sub_method)

# ── visit dispatch ────────────────────────────────────────────────────────────

"""
    visit(t::ContextTransformer, e) -> Expr | atom

Recursively rewrite `e`. Atoms (`Symbol`, literal, `QuoteNode`) pass through
unless an enclosing `Expr` decides otherwise.
"""
function visit(t::ContextTransformer, e)
    e isa Expr || return e
    return visit_expr(t, e)
end

# Helper: detect both bare `name` and qualified `NGCSimLib.name` callees.
_callee_is(callee, sym::Symbol) =
    callee === sym ||
    (
        callee isa Expr && callee.head === :. &&
        callee.args[1] === :NGCSimLib &&
        length(callee.args) >= 2 &&
        callee.args[2] isa QuoteNode &&
        callee.args[2].value === sym
    )

function visit_expr(t::ContextTransformer, e::Expr)
    # 1. Compartment field access:  c.field  or  c.sub.field
    if e.head === :.
        comp = _resolve_field_chain(t.instance, e)
        if comp !== nothing && comp.root_target !== nothing
            push!(t.needed_keys, comp.root_target)
            return :($(t.ctx_sym)[$(comp.root_target)])
        end
        # Fallthrough: leave structure alone (rare — dotted module access etc.)
        return e
    end

    # 2. set!(c.field, value) → ctx[key] = visit(value)
    if e.head === :call && length(e.args) >= 3 && _callee_is(e.args[1], :set!)
        target = e.args[2]
        value = e.args[3]
        if target isa Expr && target.head === :.
            comp = _resolve_field_chain(t.instance, target)
            if comp !== nothing && comp.root_target !== nothing
                push!(t.needed_keys, comp.root_target)
                return :($(t.ctx_sym)[$(comp.root_target)] = $(visit(t, value)))
            end
        end
    end

    # 3. get_value(c.field) → ctx[key]
    if e.head === :call && length(e.args) >= 2 && _callee_is(e.args[1], :get_value)
        target = e.args[2]
        if target isa Expr && target.head === :.
            comp = _resolve_field_chain(t.instance, target)
            if comp !== nothing && comp.root_target !== nothing
                push!(t.needed_keys, comp.root_target)
                return :($(t.ctx_sym)[$(comp.root_target)])
            end
        end
    end

    # 4. return c → return ctx (top-level only; spec contextTransformer.py:26-29)
    if e.head === :return && !t.sub_method
        if length(e.args) == 1 && e.args[1] isa Symbol
            return :(return $(t.ctx_sym))
        end
        return Expr(:return, [visit(t, a) for a in e.args]...)
    end

    # 5. Generic recursive walk
    return Expr(e.head, [visit(t, a) for a in e.args]...)
end

export ContextTransformer, visit
