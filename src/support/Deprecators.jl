# Deprecators.jl — port of ngcsimlib/_src/deprecators.py
# Spec: docs/specs/06_support_spec.md §deprecators.py (lines 310-401).
#
# Two facilities:
#   1. `@deprecated`         — wraps a function so every call emits a warn.
#   2. `deprecate_args(...)` — wraps a function so specified kwargs trigger a
#                              warn + optional rename + optional drop.
#
# Both attach the wrapped callable to an `IdDict` registry so `is_deprecated`
# / `original_of` can introspect — mirroring upstream's `_is_deprecated = True`
# / `_original = fn` sentinel attributes. The introspection path is needed
# because `contextAwareObjectMeta.py:11` checks
# `getattr(init, "_is_deprecated", False)` to refuse classes with a
# deprecated `__init__`.

# ── Registries (introspection back-pointers) ──────────────────────────────────

# wrapper → original callable. `is_deprecated(wrapper)` becomes a haskey check.
const _DEPRECATED_REGISTRY = IdDict{Any,Any}()

# ── Predicate / lookup helpers ────────────────────────────────────────────────

"""
    is_deprecated(fn) -> Bool

True iff `fn` is a wrapper produced by `@deprecated` or `deprecate_args`.
Mirrors upstream `getattr(fn, "_is_deprecated", False)`.
"""
is_deprecated(fn) = haskey(_DEPRECATED_REGISTRY, fn)

"""
    original_of(fn) -> Any

Returns the unwrapped original if `fn` is a deprecation wrapper, else `fn`
itself. Mirrors upstream `fn._original`.
"""
original_of(fn) = get(_DEPRECATED_REGISTRY, fn, fn)

# ── `@deprecated` macro ───────────────────────────────────────────────────────

"""
    @deprecated fn

Wraps `fn` so that each call emits an `ngc_warn` and then delegates. The
wrapper is registered so `is_deprecated(wrapper) == true` and
`original_of(wrapper) === fn`. Mirrors upstream `deprecated()` decorator
(deprecators.py lines 4-11).

Usage:
    foo = @deprecated old_foo
    foo(1, 2)   # emits "old_foo is deprecated" then calls old_foo(1, 2)
"""
macro deprecated(fnexpr)
    quote
        local _orig = $(esc(fnexpr))
        local _name = string(_orig)
        local _wrapped = (args...; kwargs...) -> begin
            ngc_warn(_name, " is deprecated")
            return _orig(args...; kwargs...)
        end
        _DEPRECATED_REGISTRY[_wrapped] = _orig
        _wrapped
    end
end

# ── `deprecate_args` helper ───────────────────────────────────────────────────

"""
    deprecate_args(fn; rebind=true, renames::AbstractDict)

Wraps `fn` so that any kwarg key listed in `renames` triggers an `ngc_warn`
and (if `rebind=true`) is either renamed to its replacement (when the value
is a Symbol/String) or silently dropped (when the value is `nothing`).

`renames` maps old → new (`nothing` means "removed entirely").

Mirrors upstream `deprecate_args(_rebind=True, **arg_list)` (deprecators.py
lines 14-35). Differences from upstream:
  - Julia kwargs are keyword arguments, not a positional dict, so the
    `**arg_list` style is replaced with an explicit `renames::AbstractDict`
    parameter.
  - `_rebind` is spelled `rebind` (no leading underscore — that's a Python
    convention for "callable-level private").
"""
function deprecate_args(fn; rebind::Bool=true, renames::AbstractDict)
    name = string(fn)
    # Normalize keys to Symbol so callers can pass either Dict{Symbol,...} or
    # Dict{String,...}. Values can be Nothing, Symbol, or AbstractString.
    norm = Dict{Symbol,Any}()
    for (k, v) in renames
        kk = k isa Symbol ? k : Symbol(k)
        vv = v === nothing ? nothing :
             v isa Symbol     ? v :
             v isa AbstractString ? Symbol(v) :
             ngc_error("deprecate_args: rename value for `", kk, "` must be Symbol, AbstractString, or nothing")
        norm[kk] = vv
    end

    wrapped = (args...; kwargs...) -> begin
        # `kwargs` is a NamedTuple-like Iterators.Pairs; rebuild as a Dict so
        # we can mutate. Then splat back into `fn`.
        kw = Dict{Symbol,Any}(pairs(kwargs))
        for (oldname, newname) in norm
            if haskey(kw, oldname)
                if newname === nothing
                    ngc_warn("The argument \"", oldname, "\" is deprecated for ",
                             name, ", and will no longer be supported")
                else
                    ngc_warn("The argument \"", oldname, "\" is deprecated for ",
                             name, ", use \"", newname, "\" instead")
                end
                if rebind
                    if newname !== nothing
                        kw[newname] = kw[oldname]
                    end
                    delete!(kw, oldname)
                end
            end
        end
        return fn(args...; kw...)
    end
    _DEPRECATED_REGISTRY[wrapped] = fn
    return wrapped
end

export @deprecated, deprecate_args, is_deprecated, original_of
