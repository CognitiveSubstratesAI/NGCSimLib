# Compartment.jl — port of ngcsimlib/_src/compartment/compartment.py
#                   + ngcsimlib/_src/compartment/compartmentMeta.py
# Spec: docs/specs/01_component_compartment_spec.md.
#
# A `Compartment` is a typed handle pointing into the flat global-state Dict.
# Its value lives in `GlobalState.state` under a string key
# `"<owner_path>:<name>"`; the struct just stores that key + display metadata.
#
# Key behaviors (1:1 with upstream):
#   - lifecycle: __init__ → setup! → set/get → (potentially rewire via >>)
#   - target field can be: nothing (pre-setup) | String (own key OR foreign) | AbstractOp
#   - set! refuses to write into a foreign target (self-write-only invariant)
#   - >> retargets (source >> dest makes dest read source)
#   - rewire chases one hop only (value.target, not value itself)
#
# Departures from upstream (documented):
#   - Reverse arithmetic ops (e.g. 5 - c) compute correctly in Julia by virtue
#     of multiple dispatch — upstream Python has a known bug where
#     `__rsub__(self, 5)` evaluates as `_unwrap(self) - 5` (wrong order).
#     Spec Open Question #1: port decision = correct, not faithful-to-bug.
#   - `get_needed_keys` returns a Set with the full key string, not a set of
#     individual characters (spec Open Question #2 — bug NOT ported).

# AbstractValueNode is in AbstractTypes.jl (loaded earlier). Compartment.target
# is typed as Union{Nothing, String, AbstractValueNode} so it can hold an Op
# without Operations.jl needing to be loaded first.

# ── The Compartment type ──────────────────────────────────────────────────────

"""
    Compartment{T}

A typed pointer into the global state dict. After `setup!`, the canonical
key is `"<owner_path>:<name>"` and reads/writes go through `GlobalState`.
"""
mutable struct Compartment{T} <: AbstractCompartmentLike
    initial_value::T
    name::Union{String, Nothing}
    root_target::Union{String, Nothing}
    target::Union{Nothing, String, AbstractValueNode}
    display_name::Union{String, Nothing}
    units::Union{String, Nothing}
    plot_method::Union{Function, Nothing}
    auto_save::Bool
end

"""
    Compartment(initial_value::T; display_name=nothing, units=nothing,
                plot_method=nothing, auto_save=true)

Construct an un-setup Compartment. `initial_value` is buffered; not written
to global state until `setup!` is called. Mirrors upstream `__init__`
(compartment.py:39-54).
"""
function Compartment(initial_value::T;
    display_name::Union{String, Nothing}=nothing,
    units::Union{String, Nothing}=nothing,
    plot_method::Union{Function, Nothing}=nothing,
    auto_save::Bool=true) where {T}
    return Compartment{T}(initial_value, nothing, nothing, nothing,
        display_name, units, plot_method, auto_save)
end

# ── Property-style accessors (Julia idiom: functions, not @property) ──────────

"""
    root(c::Compartment) -> Union{String, Nothing}

The canonical, immutable global-state key for `c`. `nothing` before `setup!`.
Mirrors upstream `root` property (compartment.py:56-58).
"""
root(c::Compartment) = c.root_target

"""
    targeted(c::Compartment) -> Bool

True iff `c` has been wired to read from a non-canonical source.
Mirrors upstream `targeted` property (compartment.py:64-66).
"""
targeted(c::Compartment) = !(c.target isa String) || c.target != c.root_target

"""
    target(c::Compartment) -> Union{Nothing, String, AbstractValueNode}

The current read source. Mirrors upstream `target` property (compartment.py:143-148).
"""
target(c::Compartment) = c.target

"""
    target!(c::Compartment, value)

Set `c.target`. `value` must be a `String`, `AbstractValueNode` (op), or another
`Compartment` (in which case we chase one hop to `value.target`).
Mirrors upstream `target` setter (compartment.py:150-170), with the
unreachable branches collapsed per spec Open Question #3.
"""
function target!(c::Compartment, value)
    if value isa AbstractString
        c.target = String(value)
    elseif value isa Compartment
        # Spec invariant 5 — rewire is shallow (chases value.target, not value).
        c.target = value.target
    elseif value isa AbstractValueNode  # AbstractOp
        c.target = value
    else
        ngc_error("Compartment target must be String, AbstractOp, or Compartment; got ",
            typeof(value))
    end
    return c
end

# ── Lifecycle: setup! ─────────────────────────────────────────────────────────

"""
    setup!(c::Compartment, comp_name::AbstractString, path::AbstractString)

Register `c` into the global state. Assigns `name` and `root_target`,
defaults `target` to `root_target` if not pre-wired, writes `initial_value`
into the global state dict, and registers the Compartment with the manager.

Mirrors upstream `_setup` (compartment.py:68-74). This is the moment a
Compartment becomes "live."
"""
function setup!(c::Compartment, comp_name::AbstractString, path::AbstractString)
    c.name = String(comp_name)
    c.root_target = make_key(path, comp_name)
    if c.target === nothing
        c.target = c.root_target
        # Mirrors `self.set(initial_value)` — write initial value to own slot.
        add_key!(path, comp_name, c.initial_value)
    end
    add_compartment!(c)
    return c
end

# ── set / get / value resolution ──────────────────────────────────────────────

"""
    set!(c::Compartment, value)

Write `value` into `c`'s slot. Behavior depends on `target`:
  - pre-setup (`target === nothing`)     → buffer in `initial_value`
  - wired to non-root (foreign target)   → log warn, abort
  - own slot (`target == root_target`)   → write through to global state

Mirrors upstream `set` (compartment.py:76-93).
"""
function set!(c::Compartment, value)
    if c.target === nothing
        c.initial_value = value
        return nothing
    end
    if !(c.target isa AbstractString) || c.target != c.root_target
        ngc_warn("Attempting to set ", c.target, " in ", c.root_target,
            ". Aborting!")
        return nothing
    end
    # c.target == c.root_target — write own slot.
    add_key!(_split_root(c.target)..., value)
    return nothing
end

# Helper: undo make_key to feed back into add_key! (which re-joins).
# Splits at the FIRST `:` since make_key joins on the first `:` only.
function _split_root(key::AbstractString)
    idx = findfirst(':', key)
    idx === nothing && ngc_error("Compartment.root has no ':'; got `", key, "`")
    return (String(SubString(key, 1, prevind(key, idx))),
        String(SubString(key, nextind(key, idx))))
end

"""
    get_value(c::Compartment) -> Any

Resolve `c`'s current value. Mirrors upstream `_get_value` (compartment.py:110-117):
  - pre-setup → `initial_value`
  - target is an Op → recurse via `get_value(target)`
  - target is a String → read from global state; `initial_value` fallback if absent

The `get_value(::AbstractValueNode)` generic is the canonical Compartment ↔ Op
interface — both implement it; arithmetic unwraps through it.
"""
function get_value(c::Compartment)
    if c.target === nothing
        return c.initial_value
    elseif c.target isa AbstractValueNode
        return get_value(c.target)
    else  # String key
        v = from_global_key(c.target)
        return v === nothing ? c.initial_value : v
    end
end

# NOTE: do NOT define a bare `get(c::Compartment)` here — it would shadow
# `Base.get(::AbstractDict, key, default)` for every other support file in
# this module. Callers want `get_value(c)`; the upstream `comp.get()` spelling
# is not idiomatic Julia and would create a footgun far worse than the saved
# 5 characters at call sites.

"""
    get_needed_keys(c::Compartment) -> Set{String}

The set of global-state keys this compartment needs to read. Mirrors upstream
`get_needed_keys` (compartment.py:101-108), but **without** the upstream bug
(spec Open Question #2). Upstream's `set(self.target)` on a string produces
individual characters; we return `Set([target])` with the whole key.
"""
function get_needed_keys(c::Compartment)
    if c.target isa AbstractValueNode
        return get_needed_keys(c.target)
    elseif c.target isa AbstractString
        return Set([String(c.target)])
    else  # nothing
        return Set{String}()
    end
end

# ── Arithmetic injection (replaces CompartmentMeta dunders) ───────────────────
# Spec §"Metaclass behavior": every numeric binop returns a raw value via
# _unwrap. In Julia this is multiple dispatch — define Base.<op> on
# (AbstractValueNode, Any) / (Any, AbstractValueNode) / (AbstractValueNode,
# AbstractValueNode). Multiple dispatch covers both argument orders correctly,
# so reverse-op semantics work for free (no upstream `__rsub__` bug).

"""
    unwrap(x) -> Any

Recursive value resolution. Loops `get_value` until the receiver is no
longer an `AbstractValueNode`. Mirrors upstream `_unwrap` (compartmentMeta.py:5-8).
"""
function unwrap(x::AbstractValueNode)
    while x isa AbstractValueNode
        x = get_value(x)
    end
    return x
end
unwrap(x) = x

# Generate Base.<op>(::AbstractValueNode, ::Any) etc. for every dunder in
# upstream `_BINARY_OPS` (compartmentMeta.py:11-29).
const _COMPARTMENT_BINARY_OPS = (:+, :-, :*, :/, :÷, :%, :^, :&, :⊻, :|,
    :(==), :!=, :<, :<=, :>, :>=)

for op in _COMPARTMENT_BINARY_OPS
    @eval begin
        Base.$op(a::AbstractValueNode, b::AbstractValueNode) = $op(unwrap(a), unwrap(b))
        Base.$op(a::AbstractValueNode, b) = $op(unwrap(a), unwrap(b))
        Base.$op(a, b::AbstractValueNode) = $op(unwrap(a), unwrap(b))
    end
end

# ── Wiring (>>): source >> dest retargets dest at source ──────────────────────

"""
    wire!(source::AbstractValueNode, dest::Compartment)

Retarget `dest` to read from `source`. Used by the `>>` operator. If there's
a current context, the wire is recorded via `add_connection!`.

Mirrors upstream `__rrshift__` (compartment.py:134-137). Returns `dest`.
"""
function wire!(source::AbstractValueNode, dest::Compartment)
    # Forward decl: Context.jl will define current_context/add_connection!.
    # `isdefined` lets this file compile before Context.jl is loaded.
    if isdefined(@__MODULE__, :current_context)
        ctx = current_context()
        if ctx !== nothing
            add_connection!(ctx, source, dest)
        end
    end
    target!(dest, source)
    return dest
end

Base.:(>>)(source::AbstractValueNode, dest::Compartment) = wire!(source, dest)

# ── Display ───────────────────────────────────────────────────────────────────

Base.string(c::Compartment) = string(get_value(c))
function Base.show(io::IO, c::Compartment)
    print(io, "Compartment(")
    c.root_target === nothing ? print(io, "<un-setup>") : print(io, c.root_target)
    print(io, ", value=", get_value(c), ")")
end

export Compartment,
    root, targeted, target, target!, setup!, set!, get_value,
    get_needed_keys, unwrap, wire!
