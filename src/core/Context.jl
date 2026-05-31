# Context.jl — port of ngcsimlib/_src/context/context.py
# Spec: docs/specs/02_context_spec.md §"class Context".
#
# A Context is simultaneously:
#   1. a SCOPE — entered via a Julia do-block, captures newly-constructed
#      ContextAware components into its `objects` bucket
#   2. a NAMED NODE in a global tree of all contexts (keyed by colon-path)
#   3. a CONTAINER for the compiled model — objects + connections
#
# Phase A scope: scope/registration machinery + auto-setup pipeline.
# Phase B will add `save_to_json` / `load` / full `recompile`.
#
# Spec departures from upstream:
#   - `registerObj` upstream has a bug keying duplicate-detection by object
#     identity (`__hash__`) while storing by name — we key both by name
#     uniformly (spec line 180 hazard).
#   - Sort order: priority DESCENDING during recompile, matches upstream
#     (context.py:91, reverse=True).

# ── ContextObjectType (replaces upstream Enum) ────────────────────────────────

"""
    ContextObjectType

Enum mirroring upstream `ContextObjectTypes` (context.py:20-28). Two values:
`COMPONENT` and `PROCESS`. The bucket key in `Context.objects` is the
Symbol corresponding to each.
"""
@enum ContextObjectType begin
    COMPONENT
    PROCESS
end

const _OBJECT_TYPE_STRING = Dict{ContextObjectType,Symbol}(
    COMPONENT => :component,
    PROCESS   => :process,
)

object_type_key(t::ContextObjectType) = _OBJECT_TYPE_STRING[t]

# Type tagging: subtypes of AbstractComponent automatically count as COMPONENT;
# subtypes of AbstractProcess as PROCESS. Mirrors upstream `cls._type`
# attribute set by `@component`/`@process` decorators.
object_type(::AbstractComponent) = COMPONENT
object_type(::AbstractProcess)   = PROCESS
object_type(obj) = nothing   # warn-and-skip fallback

# ── The Context type ──────────────────────────────────────────────────────────

"""
    Context

Holds a name, an absolute colon-path, typed object buckets, and a
connection map. Construct via [`Context`](@ref) (constructor below), which
is **idempotent** by path — calling `Context("foo")` twice at the same
scope returns the same instance.
"""
mutable struct Context <: AbstractContext
    name::String
    path::String
    objects::Dict{Symbol,Dict{String,Any}}
    connections::Dict{String,Any}     # dest_root → source (Compartment | Op)
    previous_path::Union{String,Nothing}
    initialized::Bool
    lock::ReentrantLock
end

# Internal allocator. Construction is wrapped by the public `Context(name)`
# below which adds the global-uniqueness guard.
_make_context(name::AbstractString, path::AbstractString) = Context(
    String(name),
    String(path),
    Dict{Symbol,Dict{String,Any}}(),
    Dict{String,Any}(),
    nothing,
    true,
    ReentrantLock(),
)

"""
    Context(name::AbstractString) -> Context

Get-or-create the Context at `<current_path>:<name>`. Two calls in the same
scope return the **same** instance — mirrors upstream `Context.__new__`
(context.py:44-53) with the global-uniqueness-by-path semantic.

Does NOT enter the scope. Use the do-block form to enter:
```
Context("world") do ctx
    # body
end
```
"""
function Context(name::AbstractString)
    cm = context_manager()
    target_path = append_path(cm; addition=String(name))
    existing = get_context(target_path)
    if existing !== nothing
        return existing::Context
    end
    ctx = _make_context(name, target_path)
    register_context_local!(String(name), ctx)
    return ctx
end

"""
    Context(f::Function, name::AbstractString) -> Context

Do-block form. Get-or-create, **enter** the scope, run `f(ctx)`, then
**exit** (popping the path and triggering `recompile!`). Mirrors Python
`with Context("name") as ctx: ...`.
"""
function Context(f::Function, name::AbstractString)
    ctx = Context(name)
    _enter!(ctx)
    try
        f(ctx)
    finally
        _exit!(ctx)
    end
    return ctx
end

# ── Enter / exit ──────────────────────────────────────────────────────────────

function _enter!(ctx::Context)
    cm = context_manager()
    @lock ctx.lock begin
        ctx.previous_path = current_path()
    end
    step_to!(ctx.path)
    return ctx
end

function _exit!(ctx::Context)
    cm = context_manager()
    # Spec hazard #1: upstream calls recompile BEFORE restoring path, and
    # if recompile raises, the path stays corrupted. We use try/finally
    # to ensure path restoration even on recompile failure (Julia idiom).
    try
        recompile!(ctx)
    finally
        prev = @lock ctx.lock ctx.previous_path
        step_to!(prev === nothing ? "" : prev)
        @lock ctx.lock (ctx.previous_path = nothing)
    end
    return ctx
end

# ── Registration ──────────────────────────────────────────────────────────────

"""
    register_obj!(ctx::Context, obj) -> Bool

Add `obj` to the appropriate type bucket. Mirrors upstream `Context.registerObj`
(context.py:105-155) but keyed by `name(obj)` for both store and
duplicate-check — upstream has a bug keying duplicate detection by object
identity (spec hazard). Returns `false` if `obj` lacks a known
`object_type`.
"""
function register_obj!(ctx::Context, obj)
    ot = object_type(obj)
    if ot === nothing
        ngc_warn("register_obj!: object of type ", typeof(obj),
                 " has no recognised ContextObjectType; skipping")
        return false
    end
    bucket_key = object_type_key(ot)

    # Need a `name` accessor — both AbstractComponent and AbstractProcess
    # have it (context_path / name fields by Phase A convention).
    obj_name = hasproperty(obj, :name) ? getproperty(obj, :name) : nothing
    obj_name === nothing && (
        ngc_error("register_obj!: object of type ", typeof(obj),
                  " has no `name` field"))

    @lock ctx.lock begin
        bucket = get!(ctx.objects, bucket_key) do
            Dict{String,Any}()
        end
        if haskey(bucket, obj_name)
            ngc_warn("Context `", ctx.path, "`: duplicate name `", obj_name,
                     "` in bucket `", bucket_key, "`; overwriting")
        end
        bucket[String(obj_name)] = obj
        return true
    end
end

"""
    add_connection!(ctx::Context, source::AbstractValueNode, dest::Compartment)

Record a wire `source >> dest` for later serialization / introspection.
Mirrors upstream `add_connection` (context.py:227-228).
"""
function add_connection!(ctx::Context, source::AbstractValueNode, dest::Compartment)
    @lock ctx.lock begin
        ctx.connections[dest.root_target === nothing ? "<unbound>" : dest.root_target] = source
    end
    return ctx
end

# ── Object lookup ─────────────────────────────────────────────────────────────

"""
    get_objects_by_type(ctx::Context, ot::ContextObjectType) -> Dict{String,Any}

Bucket lookup. Returns an empty `Dict` if the bucket is absent. Mirrors
upstream `get_objects_by_type` (context.py:157-173).
"""
function get_objects_by_type(ctx::Context, ot::ContextObjectType)
    bucket_key = object_type_key(ot)
    @lock ctx.lock begin
        return get(ctx.objects, bucket_key, Dict{String,Any}())
    end
end

"""
    get_components(ctx::Context) -> Dict{String,Any}

Alias for `get_objects_by_type(ctx, COMPONENT)`. Matches upstream
`get_components` (context.py:220-225).
"""
get_components(ctx::Context) = get_objects_by_type(ctx, COMPONENT)

"""
    get_processes(ctx::Context) -> Dict{String,Any}

Phase-A add-on, not in upstream — symmetry with `get_components`.
"""
get_processes(ctx::Context) = get_objects_by_type(ctx, PROCESS)

# ── Recompile (Phase A stub; full impl in Phase B Parser) ─────────────────────

"""
    recompile!(ctx::Context) -> Nothing

Iterate every object in every bucket, collect `is_compilable_method`-marked
ones, sort by priority descending, and call `compile!` on each. Phase A
stub: walks objects but skips the actual `compile!` step — the Parser
hasn't landed yet.

Mirrors upstream `Context.recompile` (context.py:75-103).
"""
function recompile!(ctx::Context)
    # Walk all objects in priority order. Priority comes from the Priority.jl
    # registry; default is 0.
    targets = Tuple{Int,Any}[]
    @lock ctx.lock begin
        for (_, bucket) in ctx.objects
            for (_, obj) in bucket
                # `is_compilable_method` works on types; for now we
                # heuristically include everything that subtypes
                # AbstractComponent or AbstractProcess (since they're our
                # compilable kinds).
                if obj isa AbstractComponent || obj isa AbstractProcess
                    push!(targets, (get_priority(obj), obj))
                end
            end
        end
    end
    sort!(targets; by = first, rev = true)
    for (_, obj) in targets
        # Phase B will dispatch via Parser/JIT here. Phase A: no-op,
        # since `compile!` doesn't exist yet.
        if isdefined(@__MODULE__, :compile!)
            @invokelatest compile!(obj)
        end
    end
    return nothing
end

# ── Display ───────────────────────────────────────────────────────────────────

function Base.show(io::IO, ctx::Context)
    print(io, "Context(name=\"", ctx.name, "\", path=\"", ctx.path, "\"")
    nobjs = 0
    @lock ctx.lock begin
        for (_, bucket) in ctx.objects
            nobjs += length(bucket)
        end
    end
    print(io, ", objects=", nobjs, ", connections=",
          (@lock ctx.lock length(ctx.connections)), ")")
end

export Context, ContextObjectType, COMPONENT, PROCESS,
       object_type, object_type_key, register_obj!, add_connection!,
       get_objects_by_type, get_components, get_processes,
       recompile!
