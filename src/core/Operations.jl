# Operations.jl — port of ngcsimlib/_src/operations/
# Spec: docs/specs/05_operations_spec.md.
#
# Three exports: AbstractOp (BaseOp analog), Summation, Product.
#
# An Op is a deferred, inline reducer over Compartment / Op operands. It owns
# no global-state slot; every read recomputes by walking operands' `get_value`.
# Ops compose into expression trees (operands may themselves be Ops).
#
# Key 1:1 invariants from upstream:
#   - operands stored in field `comps::Vector{AbstractValueNode}`
#   - single-operand ops behave as passthroughs (spec line 188)
#   - operand order matters (left-fold)
#   - no global registry, no Op-side caching
#   - all Ops share the abstract supertype so arithmetic injection in
#     Compartment.jl covers them too
#
# Departures from upstream (documented):
#   - `get_value` default raises rather than returning `NotImplemented`
#     (spec recommends; upstream foot-gun avoided)
#   - `ast_kernel` replaces upstream `astOp` (a Python AST node) — we use the
#     Julia callable directly since lowering target is Reactant tracing, not
#     Python AST construction (spec lines 402-414)

# ── BaseOp / AbstractOp ───────────────────────────────────────────────────────
# AbstractOp is declared in AbstractTypes.jl. Concrete ops subtype it.

"""
    get_value(op::AbstractOp) -> Any

Required interface. Concrete ops MUST implement this. Default raises rather
than silently returning a sentinel (departure from upstream
`BaseOp._get_value -> NotImplemented`, per spec recommendation).
"""
get_value(op::AbstractOp) =
    ngc_error("get_value not implemented for op type ", typeof(op))

"""
    ast_kernel(op::AbstractOp) -> Function

The binary reducer associated with this op (e.g. `+` for `Summation`, `*`
for `Product`). Replaces upstream `astOp` (a Python `ast.operator` instance)
with a direct callable, since Reactant traces Julia functions rather than
building AST. Used by [`lower`](@ref) for the compile path.
"""
ast_kernel(op::AbstractOp) =
    ngc_error("ast_kernel not implemented for op type ", typeof(op))

"""
    operands(op::AbstractOp) -> Vector{AbstractValueNode}

Read-access to the operand list. All concrete ops store a `comps` field; the
default accessor returns it. Override if a future op uses a different field
name.
"""
operands(op::AbstractOp) = op.comps

"""
    get_needed_keys(op::AbstractOp) -> Set{String}

Union of `get_needed_keys` across all operands. Mirrors upstream
`get_needed_keys` (BaseOp.py:66-73) — fixing the upstream bug where the
non-mutating `keys.union(...)` return is discarded (spec §"Hazards").
"""
function get_needed_keys(op::AbstractOp)
    keys = Set{String}()
    for c in operands(op)
        union!(keys, get_needed_keys(c))
    end
    return keys
end

"""
    lower(op::AbstractOp, ctx)

Recursive lowering for the compile path. Each operand is lowered (Compartments
become `ctx[target]`, nested ops recurse), then the op's `ast_kernel` is
left-folded across them. Mirrors upstream `BaseOp._to_ast` (BaseOp.py:30-51).

Single-operand ops pass through (spec line 188).
"""
function lower(op::AbstractOp, ctx)
    lowered = [lower(c, ctx) for c in operands(op)]
    length(lowered) == 1 && return lowered[1]
    return reduce(ast_kernel(op), lowered)
end

# Compartment lowering for the same compile-path contract.
# Eager path: simply read the current value (mirrors upstream
# `Compartment._to_ast` line 130 emitting `ctx[<key>]`).
function lower(c::Compartment, ctx)
    if c.target isa AbstractValueNode
        return lower(c.target, ctx)
    elseif c.target isa AbstractString
        return ctx[c.target]
    else
        return c.initial_value
    end
end

# ── Wiring (>>): op >> compartment retargets compartment at op ────────────────
# Mirrors upstream `BaseOp.__rshift__` (BaseOp.py:85-87). Already covered by
# the Compartment.jl definition `Base.:(>>)(::AbstractValueNode, ::Compartment)`,
# which catches AbstractOp too (since AbstractOp <: AbstractValueNode).

# ── Concrete ops ──────────────────────────────────────────────────────────────

"""
    Summation(comps...) <: AbstractOp

Sums an arbitrary number of value nodes. Identity = 0. Left-fold.

Mirrors upstream `Summation` (Summation.py:5-16).
"""
struct Summation <: AbstractOp
    comps::Vector{AbstractValueNode}
end
Summation(comps::AbstractValueNode...) = Summation(collect(AbstractValueNode, comps))

ast_kernel(::Summation) = +
function get_value(op::Summation)
    isempty(op.comps) && return 0
    return reduce(+, (get_value(c) for c in op.comps))
end

"""
    Product(comps...) <: AbstractOp

Elementwise product of value nodes. Identity = 1. Left-fold.

Mirrors upstream `Product` (Product.py:5-19). Note that upstream `Summation`
uses `sum(self._comps)` (relying on metaclass `__add__`) while `Product` does
manual `comp.get()` — asymmetric upstream but consistent here.
"""
struct Product <: AbstractOp
    comps::Vector{AbstractValueNode}
end
Product(comps::AbstractValueNode...) = Product(collect(AbstractValueNode, comps))

ast_kernel(::Product) = *
function get_value(op::Product)
    isempty(op.comps) && return 1
    return reduce(*, (get_value(c) for c in op.comps))
end

# ── Display ───────────────────────────────────────────────────────────────────

function Base.show(io::IO, op::AbstractOp)
    print(io, nameof(typeof(op)), "(")
    for (i, c) in enumerate(operands(op))
        i > 1 && print(io, ", ")
        show(io, c)
    end
    print(io, ")")
end

export AbstractOp, Summation, Product, ast_kernel, operands, lower
