# ContextAware.jl — port of ngcsimlib/_src/context/contextAwareObject.py
#                    + contextAwareObjectMeta.py
# Spec: docs/specs/02_context_spec.md §"ContextAwareObject" + §"ContextAwareObjectMeta".
#
# Upstream uses a Python metaclass (`ContextAwareObjectMeta`) to intercept
# `MyComponent(...)` constructor calls and:
#   1. Push the new object's name onto the manager's path
#   2. Run __init__ (so any nested Context construction sees the deeper path)
#   3. After __init__, walk the new instance's `compartments` and call
#      `comp._setup(comp_name, gcm.current_path)` on each
#   4. Pop the path
#   5. Register the new instance in the (now-enclosing) `current_context()`
#
# Julia has no metaclasses, but we don't need them: every `@ngc_component`
# subtype OR hand-rolled `<: AbstractComponent` subtype calls `post_init!`
# explicitly after construction. The `@ngc_component` macro could be extended
# to inject this call into the generated kw constructor, but for Phase A we
# expose `post_init!` as a public function so the call site is explicit and
# greppable.
#
# Phase B will revisit auto-injection once Parser + Process integration is
# stable and the call-site count makes the macro pay off.

"""
    post_init!(c::AbstractComponent) -> AbstractComponent

The "after the constructor returns" hook that:

1. Captures `context_path` from the active `ContextManager` (no-op if `c`
   already has a non-empty context_path).
2. For each `Compartment` field of `c`, calls
   [`setup!`](@ref) with `field_name` and `<context_path>:<c.name>` —
   establishing the full global-state key `"<ctx>:<comp>:<field>"`.
3. If a `current_context()` is active, calls [`register_obj!`](@ref) to
   record `c` in the enclosing Context's COMPONENT bucket.

Mirrors upstream `ContextAwareObjectMeta.__call__` (Meta.py:48-70) without
the metaclass machinery. Returns `c` for chaining.

Idempotent — calling twice is safe but inefficient (re-runs setup!).
"""
function post_init!(c::AbstractComponent)
    cp = current_path()

    # Capture the context_path if the constructor didn't set one.
    if isempty(c.context_path)
        c.context_path = cp
    end

    # Compute the full prefix under which compartments are keyed:
    # "<ctx>:<comp_name>" (or just "<comp_name>" at root).
    comp_path = isempty(cp) ? c.name : string(cp, ":", c.name)

    # Auto-setup each Compartment field. setup! is the Compartment-side
    # half of this handshake (Compartment.jl line 122).
    for (field_name, comp) in compartments(c)
        # Skip already-setup compartments so re-running this is safe.
        if comp.root_target === nothing
            setup!(comp, String(field_name), comp_path)
        end
    end

    # Register in the enclosing Context (if any).
    ctx = current_context()
    if ctx !== nothing
        register_obj!(ctx, c)
    end

    return c
end

# ── `@context_aware` macro (constructor-wrapping convenience) ─────────────────

"""
    @context_aware ConstructorCall

Convenience macro: wraps a constructor call so `post_init!` is invoked on
the returned instance automatically. Mirrors what upstream's metaclass
does invisibly — here it's opt-in and explicit.

```
@context_aware RateCell(name="layer1", voltage=Compartment(zeros(16)))
```

is equivalent to:

```
let c = RateCell(name="layer1", voltage=Compartment(zeros(16)))
    post_init!(c)
end
```

Optional for `@ngc_component` types — `post_init!(c)` can be called
directly. Phase B may inject this into the generated kw constructor so
the macro becomes mandatory only for hand-rolled subtypes.
"""
macro context_aware(ctor_call)
    quote
        let _c = $(esc(ctor_call))
            $(GlobalRef(NGCSimLib, :post_init!))(_c)
            _c
        end
    end
end

export post_init!, @context_aware
