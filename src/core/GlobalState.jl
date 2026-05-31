# GlobalState.jl — port of ngcsimlib/_src/global_state/manager.py
# Spec: docs/specs/06_support_spec.md §global_state/manager.py (lines 404-505).
#
# Central data plane: every compartment value lives here, keyed by a composite
# `"<path>:<local_key>"` string. Upstream relies on Python's GIL; Julia has
# no GIL, so we add a `ReentrantLock`. This is the broadest-reach module in
# the codebase (touched by every Process, Compartment, Operation, Context).
#
# 1.12 idioms used:
#   - `OncePerProcess` for lazy singleton construction (one-shot init, safe
#     across precompile/load boundary, replaces the `const Ref` + `__init__`
#     dance for state that needs to exist exactly once).
#   - `@lock` macro for mutation guards (cleaner than `lock(l) do … end`).
#
# Key format (upstream line 28): `"<path>:<local_key>"`.

# ── Manager struct ────────────────────────────────────────────────────────────

"""
    GlobalStateManager

Holds the entire runtime state of every compartment plus the registry of
compartment objects. One per process — see `global_state_manager()`.

Fields (private; access via the public API below):
  - `state::Dict{String,Any}`           — `<path>:<local_key>` → value
  - `compartments::Dict{String,AbstractCompartmentLike}` — root → compartment
  - `lock::ReentrantLock`               — NEW vs upstream; Python relies on GIL
"""
mutable struct GlobalStateManager
    state::Dict{String, Any}
    compartments::Dict{String, AbstractCompartmentLike}
    lock::ReentrantLock
end

GlobalStateManager() = GlobalStateManager(
    Dict{String, Any}(),
    Dict{String, AbstractCompartmentLike}(),
    ReentrantLock()
)

# ── Singleton via OncePerProcess (1.12 idiom) ─────────────────────────────────
# `OncePerProcess{T}` returns a callable that constructs `T` exactly once per
# process and returns the same instance on every subsequent call. Safer than
# a `const Ref` + `__init__` for state that must be unique across the entire
# Julia session (no risk of construction during precompile, no risk of double
# init).
const global_state_manager = OncePerProcess{GlobalStateManager}() do
    GlobalStateManager()
end

# ── Key construction ──────────────────────────────────────────────────────────

"""
    make_key(path::AbstractString, local_key::AbstractString) -> String

Build the composite global key. Mirrors upstream `make_key` (manager.py:18-28):
`f"{path}:{local_key}"`. Pure function — no state access, no lock needed.
"""
@inline make_key(path::AbstractString, local_key::AbstractString) =
    string(path, ':', local_key)

# ── Compartment registry ──────────────────────────────────────────────────────

"""
    add_compartment!(c::AbstractCompartmentLike) -> Nothing

Register `c` under its `root` key. Mirrors upstream `add_compartment`
(manager.py:12-13). `c.root` must already be set; this is a registration
operation, not an allocation.
"""
function add_compartment!(c::AbstractCompartmentLike)
    gsm = global_state_manager()
    # `c.root_target` is the Julia struct-field name for what upstream calls
    # `c.root` (manager.py:13). Compartment.jl exposes `root(c)` as the
    # accessor; we read the field directly here to keep the singleton free
    # of forward-decl dependencies on Compartment.jl's public surface.
    @lock gsm.lock begin
        gsm.compartments[c.root_target] = c
    end
    return nothing
end

"""
    get_compartment(root::AbstractString) -> AbstractCompartmentLike

Look up a registered compartment by its root key. Throws `KeyError` if missing,
matching upstream `get_compartment` (manager.py:15-16) which does a bare
`dict[key]` lookup with no fallback.
"""
function get_compartment(root::AbstractString)
    gsm = global_state_manager()
    @lock gsm.lock begin
        return gsm.compartments[String(root)]
    end
end

# ── State key/value plane ─────────────────────────────────────────────────────

"""
    check_key(global_key::AbstractString) -> Bool

True if `global_key` is currently present in the state dict. Mirrors
upstream `check_key` (manager.py:30-39).
"""
function check_key(global_key::AbstractString)
    gsm = global_state_manager()
    @lock gsm.lock begin
        return haskey(gsm.state, String(global_key))
    end
end

"""
    add_key!(path::AbstractString, local_key::AbstractString, value) -> Nothing

Bind `value` under `<path>:<local_key>`. Overwrites any existing entry.
Mirrors upstream `add_key` (manager.py:41-52).
"""
function add_key!(path::AbstractString, local_key::AbstractString, value)
    gsm = global_state_manager()
    @lock gsm.lock begin
        gsm.state[make_key(path, local_key)] = value
    end
    return nothing
end

"""
    from_global_key(key::AbstractString) -> Union{Any, Nothing}

Soft lookup by composite key. Returns `nothing` if absent. Mirrors upstream
`from_global_key` (manager.py:54-63) which uses `dict.get(key, None)`.
"""
function from_global_key(key::AbstractString)
    gsm = global_state_manager()
    @lock gsm.lock begin
        return get(gsm.state, String(key), nothing)
    end
end

"""
    from_local_key(path::AbstractString, local_key::AbstractString) -> Union{Any, Nothing}

Soft lookup, combining `make_key` + `from_global_key`. Mirrors upstream
`from_local_key` (manager.py:65-77).
"""
from_local_key(path::AbstractString, local_key::AbstractString) =
    from_global_key(make_key(path, local_key))

"""
    set_state!(state::AbstractDict) -> Nothing

**Partial-overwrite** semantics (merge, not replace). Mirrors upstream
`set_state` (manager.py:79-86) which does `self.__state.update(state)`. A
JIT-compiled process body produces only the keys it touched; this merges
them back into the singleton without dropping untouched keys.

The setter version `gsm.state = {...}` in Python (manager.py:95-102) also
delegates to `update`, so there is no "full replace" path in the upstream
API at all.
"""
function set_state!(state::AbstractDict)
    gsm = global_state_manager()
    @lock gsm.lock begin
        for (k, v) in state
            gsm.state[String(k)] = v
        end
    end
    return nothing
end

"""
    get_state() -> Dict{String,Any}

Returns a **defensive copy** of the state dict. Mutating the result does NOT
mutate the singleton. Mirrors upstream `state` property (manager.py:88-93)
which returns `self.__state.copy()`.
"""
function get_state()
    gsm = global_state_manager()
    @lock gsm.lock begin
        return copy(gsm.state)
    end
end

# ── Test/dev helpers ──────────────────────────────────────────────────────────

"""
    reset_global_state!() -> Nothing

Clear the singleton's state + compartment dicts. Not in upstream surface;
needed for test isolation. Does NOT replace the lock — same lock survives.
"""
function reset_global_state!()
    gsm = global_state_manager()
    @lock gsm.lock begin
        empty!(gsm.state)
        empty!(gsm.compartments)
    end
    return nothing
end

export GlobalStateManager, global_state_manager,
    make_key, add_compartment!, get_compartment,
    check_key, add_key!, from_global_key, from_local_key,
    set_state!, get_state, reset_global_state!
