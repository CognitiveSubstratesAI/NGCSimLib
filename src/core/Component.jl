# Component.jl — port of ngcsimlib/_src/component.py
#                  + the Component slice of context/contextAwareObject.py
# Spec: docs/specs/01_component_compartment_spec.md.
#
# A `Component` is a user-defined biophysical unit (neuron layer, synapse
# bank, ...) that owns named `Compartment` fields and exposes `@compilable`
# methods. Upstream `Component(ContextAwareObject)` is the Python base
# class; Julia's analog is the abstract type `AbstractComponent` (declared
# in AbstractTypes.jl) with concrete subtypes defined by users.
#
# Required protocol on every subtype:
#   - `name::String`             — user-supplied identifier
#   - `context_path::String`     — set from the active Context at construction
#                                   (empty `""` until Context is wired)
#   - any number of `Compartment` fields — discovered via `compartments(c)`
#
# Optional protocol:
#   - `args::Vector{Any}`        — for to_json (populated by macro path)
#   - `kwargs::Dict{Symbol,Any}` — same
#
# Spec departures from upstream:
#   - `vars(self)` → `fieldnames(typeof(c))`. Safer (only declared fields,
#     not dict-injected extras) — see spec Open Question #4.
#   - Decorator soup (`@component`, class-level `@compilable`) collapses to
#     "subtype AbstractComponent" — the type itself IS the tag (spec line 305).

# ── Accessors ─────────────────────────────────────────────────────────────────

"""
    name(c::AbstractComponent) -> String

Read the component's identifier. Subtypes must declare a `name::String` field.
Mirrors upstream `self.name` set by `ContextAwareObject.__init__`
(contextAwareObject.py:16-18).
"""
name(c::AbstractComponent) = c.name

"""
    context_path(c::AbstractComponent) -> String

Read the component's context path — the dot-delimited prefix it was
constructed under. Set from `ContextManager.current_path` at instantiation
(Phase A: defaults to `""` until Context.jl is wired).
"""
context_path(c::AbstractComponent) = c.context_path

"""
    compartments(c::AbstractComponent) -> Vector{Tuple{Symbol, AbstractCompartmentLike}}

Walk `fieldnames(typeof(c))` and return `(field_name, compartment)` pairs
for every field whose value is `<: AbstractCompartmentLike`. Mirrors upstream
`Component.compartments` property (component.py:19-26) which iterates
`vars(self)` — Julia's `fieldnames` walk is safer (declared fields only).
"""
function compartments(c::AbstractComponent)
    pairs = Tuple{Symbol, AbstractCompartmentLike}[]
    for f in fieldnames(typeof(c))
        v = getfield(c, f)
        if v isa AbstractCompartmentLike
            push!(pairs, (f, v))
        end
    end
    return pairs
end

# ── `@ngc_component` convenience macro for user component types ───────────────

"""
    @ngc_component mutable struct Foo
        v::Compartment{Vector{Float32}}
        # ... more fields
    end

Inject the standard `name::String`, `context_path::String`,
`args::Vector{Any}`, `kwargs::Dict{Symbol,Any}` fields plus
`<: AbstractComponent` supertype declaration, then emit a kw-style
constructor that defaults the standard fields and accepts the
user-declared fields as keyword arguments.

Usage:
```
@ngc_component mutable struct RateCell
    voltage::Compartment{Vector{Float32}}
end

cell = RateCell(name="layer1",
                voltage = Compartment(zeros(Float32, 16)))
```

Manual alternative: declare your own
`mutable struct Foo <: AbstractComponent` with the same five standard
fields plus your compartments. The macro is a convenience, not a
requirement.
"""
macro ngc_component(structdef)
    if !(structdef isa Expr && structdef.head === :struct)
        error("@ngc_component expects a `mutable struct ... end` definition")
    end
    is_mutable = structdef.args[1]
    is_mutable || error("@ngc_component requires a `mutable struct` (compartments mutate)")

    typename_expr = structdef.args[2]
    # Normalize: `Foo` or `Foo <: Bar` — we override the supertype with
    # AbstractComponent unconditionally (1:1 with upstream's Component
    # inheritance from ContextAwareObject).
    typename = typename_expr isa Symbol ? typename_expr : typename_expr.args[1]

    body = structdef.args[3]
    user_fields = filter(x -> !(x isa LineNumberNode), body.args)

    standard_fields = [
        :(name::String),
        :(context_path::String),
        :(args::Vector{Any}),
        :(kwargs::Dict{Symbol, Any})
    ]

    new_body = Expr(:block, standard_fields..., user_fields...)
    new_struct = Expr(:struct, true,
        :($typename <: $(GlobalRef(NGCSimLib, :AbstractComponent))),
        new_body)

    # Build a keyword constructor: `Foo(; name="", context_path="", args=Any[], kwargs=Dict(), user_field=...)`
    user_field_syms = Symbol[]
    for f in user_fields
        # Each user field is `:(name::Type)` or `:name`
        sym = f isa Expr && f.head === :(::) ? f.args[1] : f
        push!(user_field_syms, sym)
    end

    kw_args = Expr(:parameters,
        Expr(:kw, :name, ""),
        Expr(:kw, :context_path, ""),
        Expr(:kw, :args, :(Any[])),
        Expr(:kw, :kwargs, :(Dict{Symbol, Any}())),
        (Expr(:kw, s, :nothing) for s in user_field_syms)...
    )
    ctor = Expr(:function,
        Expr(:call, typename, kw_args),
        Expr(:block,
            [
                :(
                    $s === nothing && error(
                        $(string(
                            "@ngc_component constructor: keyword `", s, "` is required"
                        ))
                    )
                ) for s in user_field_syms
            ]...,
            Expr(:call, typename, :name, :context_path, :args, :kwargs, user_field_syms...)
        )
    )

    return esc(Expr(:block, new_struct, ctor))
end

# ── `@compilable` macro for marking methods JIT-amenable ──────────────────────

# TWO registration mechanisms keep `@compilable` precompile-safe:
#
#  1. **Dict cache** (`_COMPILABLE_METHODS`). Fast lookup at runtime. Populated
#     by `_register_compilable!`. SURVIVES precompile only when the @compilable
#     usage is in the same module as the Dict (NGCSimLib itself). Cross-module
#     mutations are scoped to the calling module's snapshot and do NOT show up
#     in NGCSimLib's loaded state — that's a Julia precompile rule, not a
#     bug we can fix here.
#
#  2. **Method-table dispatch** (`_compilable_entry_dispatch(::Type, ::Val)`).
#     The macro emits an OVERLOAD of this generic per (receiver type, method
#     name). Method definitions are preserved across precompile (they're a
#     core part of Julia's type system), so a foreign package (e.g. NGCLearn)
#     that defines `@compilable advance_state!(c::LIFCell, ...)` survives
#     precompile via this mechanism even when the Dict mutation is lost.
#
# `get_compilable_entry` tries the Dict first (fast), then falls back to the
# method table (precompile-safe) and lazy-caches the result.
const _COMPILABLE_METHODS = Dict{
    Tuple{Type, Symbol},
    NamedTuple{(:args, :body, :mod), Tuple{Vector{Any}, Expr, Module}}
}()

"""
    _compilable_entry_dispatch(::Type{T}, ::Val{name}) -> NamedTuple{(:args, :body)}

Method-table-based registry of `@compilable` entries. The `@compilable`
macro overloads this for each `(receiver_type, method_name)` pair. Used as
a precompile-safe fallback when the `_COMPILABLE_METHODS` Dict cache misses
(cross-module case).

Throws `MethodError` for unregistered pairs.
"""
function _compilable_entry_dispatch end

"""
    _register_compilable!(receiver_type::Type, name::Symbol,
                          args::AbstractVector, body::Expr)

Internal: stash a method's args + body in the Dict cache. Called by macro
expansion of [`@compilable`](@ref). The macro ALSO emits an
`_compilable_entry_dispatch` method definition for precompile safety.
"""
function _register_compilable!(receiver_type::Type, name::Symbol,
    args::AbstractVector, body::Expr, mod::Module=Main)
    _COMPILABLE_METHODS[(receiver_type, name)] = (
        args=collect(Any, args), body=body, mod=mod
    )
    return nothing
end

"""
    @compilable function name(c::MyComponent, ...) ... end

Mark a method as JIT-compilable. Both:
  1. Defines the method normally (eager Julia dispatch still works).
  2. Registers the method body `Expr` in `_COMPILABLE_METHODS` for the
     Parser to consume at compile time.

The first argument's type annotation determines the receiver type used as
the registry key. Methods without a typed first arg fall back to `Any`
(useful only for free functions; not the intended use).

Mirrors upstream `@compilable` (parser/utils.py:8-16) which sets
`fn._is_compilable = True` and is checked by the Parser when walking
class methods.
"""
macro compilable(fdef)
    fdef isa Expr ||
        error("@compilable expects a function definition; got $(typeof(fdef))")

    # Support both `function f(...) ... end` and `f(...) = ...`
    if !(
        fdef.head === :function || (fdef.head === :(=) && fdef.args[1] isa Expr &&
         fdef.args[1].head === :call)
    )
        error("@compilable expects a function or assignment-form function definition")
    end

    sig = fdef.args[1]
    body = fdef.args[2]
    body isa Expr || (body = Expr(:block, body))

    fname = if sig.args[1] isa Symbol
        sig.args[1]
    elseif sig.args[1] isa Expr && sig.args[1].head === :(.)
        sig.args[1].args[end].value
    else
        sig.args[1]
    end
    fname isa Symbol ||
        error("@compilable: cannot extract a Symbol function name from $(sig.args[1])")

    # First positional arg, ignoring `;` parameters block at args[2] if present
    first_arg_idx =
        if (
            length(sig.args) >= 2 && sig.args[2] isa Expr &&
            sig.args[2].head === :parameters
        )
            3
        else
            2
        end
    if length(sig.args) < first_arg_idx
        receiver_type_expr = :Any
    else
        first_arg = sig.args[first_arg_idx]
        receiver_type_expr =
            (first_arg isa Expr && first_arg.head === :(::)) ?
            first_arg.args[end] :
            :Any
    end

    # Capture the full arg list (everything after the function name in `sig`).
    args_list = sig.args[2:end]

    # The macro emits THREE things:
    #   1. The original function definition (eager Julia method dispatch).
    #   2. A Dict-cache registration (`_register_compilable!`) — fast lookup
    #      at runtime, works within a single module's precompile.
    #   3. A method overload of `_compilable_entry_dispatch(::Type{T}, ::Val{name})`
    #      — precompile-safe across module boundaries (method tables ARE
    #      preserved by precompile, unlike Dict mutations).
    # `__module__` is the module the macro was invoked from — captured so the
    # Parser can eval the rewritten function back into that namespace and
    # resolve any module-local names referenced in the body (e.g., private
    # helper functions in NGCLearn).
    return quote
        $(esc(fdef))
        $(GlobalRef(NGCSimLib, :_register_compilable!))(
            $(esc(receiver_type_expr)),
            $(QuoteNode(fname)),
            $(QuoteNode(args_list)),
            $(QuoteNode(body)),
            $(__module__)
        )
        function $(GlobalRef(NGCSimLib, :_compilable_entry_dispatch))(
            ::Type{$(esc(receiver_type_expr))}, ::Val{$(QuoteNode(fname))}
        )
            return (
                args=$(QuoteNode(args_list)),
                body=$(QuoteNode(body)),
                mod=$(__module__)
            )
        end
        nothing
    end
end

"""
    is_compilable_method(T::Type, name::Symbol) -> Bool

True iff a method named `name` was defined with `@compilable` for receivers
of type `T` (or any supertype of `T` that registered the method). Checks the
Dict cache first, then the method-table fallback (precompile-safe).
"""
function is_compilable_method(T::Type, name::Symbol)
    # Walk T plus its supertype chain, checking both registries each step.
    s = T
    while s !== Any
        haskey(_COMPILABLE_METHODS, (s, name)) && return true
        hasmethod(_compilable_entry_dispatch, Tuple{Type{s}, Val{name}}) && return true
        s = supertype(s)
    end
    return false
end

"""
    get_compilable_body(T::Type, name::Symbol) -> Expr

Retrieve the registered body `Expr` for `(T, name)`, walking supertypes
if necessary. Raises if not registered.
"""
function get_compilable_body(T::Type, name::Symbol)
    return get_compilable_entry(T, name).body
end

"""
    get_compilable_signature(T::Type, name::Symbol) -> Vector{Any}

Retrieve the registered arg list `Vector` for `(T, name)`. First element is
the receiver (e.g. `:(c::T)`), rest are the method's positional/kwarg specs.
"""
function get_compilable_signature(T::Type, name::Symbol)
    return get_compilable_entry(T, name).args
end

"""
    get_compilable_entry(T::Type, name::Symbol) -> NamedTuple{(:args, :body), …}

Internal: full registry entry for `(T, name)`, walking supertypes. Tries the
Dict cache first, then the precompile-safe method-table fallback. Lazy-caches
fallback results into the Dict for fast subsequent lookups.
"""
function get_compilable_entry(T::Type, name::Symbol)
    s = T
    while s !== Any
        # Dict cache (fast path; populated by `_register_compilable!`).
        haskey(_COMPILABLE_METHODS, (s, name)) && return _COMPILABLE_METHODS[(s, name)]
        # Method-table fallback (precompile-safe). Catch MethodError to walk
        # the supertype chain rather than propagate.
        if hasmethod(_compilable_entry_dispatch, Tuple{Type{s}, Val{name}})
            entry = _compilable_entry_dispatch(s, Val(name))
            # Cache it under the original `T` key so subsequent lookups skip
            # the supertype walk + MethodError dance.
            _COMPILABLE_METHODS[(T, name)] = entry
            return entry
        end
        s = supertype(s)
    end
    ngc_error("no @compilable method `", name, "` registered for type ", T)
end

"""
    compilable_methods(T::Type) -> Vector{Symbol}

All method names registered for `T` (including those registered for any of
its supertypes). Enumerates BOTH the Dict cache AND the method-table
fallback (which captures cross-module precompile-safe registrations).
"""
function compilable_methods(T::Type)
    names = Set{Symbol}()
    # 1. Dict cache (covers same-module registrations).
    for ((rt, nm), _) in _COMPILABLE_METHODS
        T <: rt && push!(names, nm)
    end
    # 2. Method-table fallback. Each `_compilable_entry_dispatch` overload has
    # signature `Tuple{Type{R}, Val{NameSym}}` — recover `(R, NameSym)` by
    # introspecting `m.sig.parameters`. Any `R` such that `T <: R` matches.
    for m in methods(_compilable_entry_dispatch)
        params = Base.unwrap_unionall(m.sig).parameters
        length(params) >= 3 || continue
        # params[1] = typeof(_compilable_entry_dispatch); [2] = Type{R}; [3] = Val{name}
        type_param = params[2]
        val_param = params[3]
        type_param isa DataType && type_param.name === Type.body.name || continue
        val_param isa DataType && val_param.name === Val.body.name || continue
        R = type_param.parameters[1]
        nm = val_param.parameters[1]
        nm isa Symbol || continue
        T <: R && push!(names, nm)
    end
    return sort(collect(names))
end

# ── Display ───────────────────────────────────────────────────────────────────

function Base.show(io::IO, c::AbstractComponent)
    print(io, nameof(typeof(c)), "(name=\"", name(c), "\"")
    cps = compartments(c)
    if !isempty(cps)
        print(io, ", compartments=[")
        for (i, (f, _)) in enumerate(cps)
            i > 1 && print(io, ", ")
            print(io, f)
        end
        print(io, "]")
    end
    print(io, ")")
end

export name, context_path, compartments,
    @ngc_component, @compilable,
    is_compilable_method, get_compilable_body, get_compilable_signature,
    compilable_methods
