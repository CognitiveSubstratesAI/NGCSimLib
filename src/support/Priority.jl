# Priority.jl — port of ngcsimlib/_src/utils/priority.py
# Spec: docs/specs/06_support_spec.md §utils/priority.py (lines 585-638).
#
# Upstream is a 7-line decorator factory that mutates `fn._priority = value`
# in place. Julia functions cannot carry arbitrary attributes, so we keep an
# external `IdDict` registry keyed by the callable.
#
# Consumer contract (preserved 1:1):
#   - jointProcess.py:17-18 reads `process._priority` to bias joint priority
#     downward by 1 each time a higher-priority child is added.
#   - context.py:85,93,334 uses `getattr(obj, "_priority", None) or 0` as a
#     sort key — i.e. unregistered → 0.
#
# So `get_priority(fn)` returns 0 for any unregistered callable (NOT `nothing`),
# matching the upstream fallback.

# ── Module-level singleton registry ───────────────────────────────────────────

# IdDict keyed by object identity. Works for functions, methods, callable
# structs alike. Mirrors the per-function _priority attribute upstream.
const _PRIORITY_REGISTRY = IdDict{Any,Int}()

# ── Public API ────────────────────────────────────────────────────────────────

"""
    priority!(fn, value::Integer) -> fn

Tag `fn` with priority `value`. Returns `fn` unmodified — the registry is the
only thing that changed. Mirrors upstream `@priority(value)` decorator
(priority.py lines 1-7); registers in place and returns the callable.

`!` suffix per Julia convention: mutates external state (the registry).
"""
function priority!(fn, value::Integer)
    _PRIORITY_REGISTRY[fn] = Int(value)
    return fn
end

"""
    get_priority(fn) -> Int

Look up the priority registered for `fn`. Returns `0` if unregistered,
matching upstream `getattr(obj, "_priority", None) or 0` fallback
(context.py:85,93,334).
"""
get_priority(fn) = get(_PRIORITY_REGISTRY, fn, 0)

"""
    has_priority(fn) -> Bool

True iff `fn` has been explicitly tagged via `priority!`. Distinguishes the
"unregistered, defaulted to 0" case from "explicitly tagged with 0".
"""
has_priority(fn) = haskey(_PRIORITY_REGISTRY, fn)

export priority!, get_priority, has_priority
