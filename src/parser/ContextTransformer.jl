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

# Sentinel returned by `_resolve_field_chain_value` when the dotted chain
# can't be walked on the live instance (typical case: module access like
# `NGCSimLib.set!` where `NGCSimLib` is a Module, not the receiver).
const _UNRESOLVED_FIELD_CHAIN = :__NGCSimLib_unresolved_field_chain__

"""
    _resolve_field_chain_value(instance, head::Expr) -> Any

Walk the dotted chain `head` on `instance` via `getproperty` and return the
final resolved value, OR the sentinel `_UNRESOLVED_FIELD_CHAIN` if any step
fails. Unlike [`_resolve_field_chain`](@ref) this returns ALL resolved
values, not just Compartments — used by the visitor to inline scalar
hyperparameter accesses (`c.tau_m`, `c.is_stateful`, etc.) as trace-time
constants.
"""
function _resolve_field_chain_value(instance, head::Expr)
    head.head === :. || return _UNRESOLVED_FIELD_CHAIN
    # Linearise the chain into innermost-first field path:
    # `:(c.a.b.c)` is `Expr(:., Expr(:., Expr(:., :c, :(:a)), :(:b)), :(:c))`.
    path = Symbol[]
    cur = head
    while cur isa Expr && cur.head === :.
        length(cur.args) == 2 || return _UNRESOLVED_FIELD_CHAIN
        field = cur.args[2]
        f = if field isa QuoteNode
            field.value
        elseif field isa Symbol
            field
        else
            nothing
        end
        f === nothing && return _UNRESOLVED_FIELD_CHAIN
        push!(path, f)
        cur = cur.args[1]
    end
    cur isa Symbol || return _UNRESOLVED_FIELD_CHAIN
    reverse!(path)
    val = instance
    for f in path
        hasproperty(val, f) || return _UNRESOLVED_FIELD_CHAIN
        val = getproperty(val, f)
    end
    return val
end

"""
    _resolve_field_chain(instance, head::Expr) -> Union{Compartment, Nothing}

Compartment-only convenience: returns the resolved value when it's a
Compartment, `nothing` in every other case (unresolved chain OR resolved
to a non-Compartment value). Used at the `set!` / `get_value` call sites
where only the Compartment branch is meaningful.

For the value-inlining path used by `c.field` direct access, see
[`_resolve_field_chain_value`](@ref).
"""
function _resolve_field_chain(instance, head::Expr)
    val = _resolve_field_chain_value(instance, head)
    val === _UNRESOLVED_FIELD_CHAIN && return nothing
    return val isa Compartment ? val : nothing
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
    # 1. Field access:  c.field  or  c.sub.field
    if e.head === :.
        val = _resolve_field_chain_value(t.instance, e)
        if val === _UNRESOLVED_FIELD_CHAIN
            # The `:.` head is NOT a field chain on the instance. Two cases:
            #   - a module-qualified name (`NGCSimLib.set!`), or
            #   - an explicit broadcast `f.(args)` (which ALSO has head `:.`,
            #     with args[2] the call's argument tuple).
            # In both cases we must still RECURSE into the subtree (case 5) —
            # otherwise a broadcast like `max.(_v, c.v_min)` would be returned
            # verbatim and any `c.field` nested inside it would never be
            # rewritten (leaving a dangling receiver ref in the pure function).
            # Module-qualified names reconstruct identically under the walk.
            return Expr(e.head, [visit(t, a) for a in e.args]...)
        elseif val isa Compartment
            if val.root_target !== nothing
                push!(t.needed_keys, val.root_target)
                return :($(t.ctx_sym)[$(val.root_target)])
            else
                # Pre-`setup!` Compartment in a method body — leave the
                # access untouched. (Compartments owned by a Component
                # going through parse_method should always be set up via
                # post_init!; falling here means the body referenced one
                # that wasn't, and we can't synthesize a key.)
                return e
            end
        else
            # Non-Compartment field — scalar hyperparameter, Bool flag,
            # function field, etc. Inline as a trace-time literal. Julia's
            # AST accepts arbitrary values as literal nodes, so embedding
            # the resolved value directly produces a valid Expr that no
            # longer references the original receiver `c`.
            return val
        end
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
