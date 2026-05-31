# ContextManager.jl — port of ngcsimlib/_src/context/context_manager.py
# Spec: docs/specs/02_context_spec.md §"__context_manager".
#
# A process-wide singleton tracking:
#   - `contexts`     : every Context ever created, keyed by full colon-path
#   - `current_path` : mutable stack of segments naming the active path
#   - `separator`    : path separator (default ":")
#
# Singleton via `OncePerProcess` (per decisions.md #1). The lock lives inside
# the struct (per decisions.md #6) — concurrent `enter!`/`exit!` from threads
# would otherwise race on `current_path`.
#
# Forward declaration: `Context` is defined in Context.jl (loaded after this
# file). We use `Any` here for the `contexts` value type to break the cycle,
# and assert `<: AbstractContext` at the registration call site.

# ── Manager struct ────────────────────────────────────────────────────────────

"""
    ContextManager

Process-wide registry of every `Context` plus the mutable "current path"
that determines which Context auto-captures newly-constructed components.
"""
mutable struct ContextManager
    contexts::Dict{String, AbstractContext}
    current_path::Vector{String}
    separator::String
    lock::ReentrantLock
end

ContextManager(separator::AbstractString=":") = ContextManager(
    Dict{String, AbstractContext}(),
    String[],
    String(separator),
    ReentrantLock()
)

# ── Singleton (OncePerProcess) ────────────────────────────────────────────────

const context_manager = OncePerProcess{ContextManager}() do
    ContextManager()
end

# ── Path arithmetic ───────────────────────────────────────────────────────────

"""
    join_path(cm::ContextManager, path=nothing) -> String

Join `path` (or the current path if `nothing`) into a colon-string. Mirrors
upstream `join_path` (context_manager.py:120-133).
"""
function join_path(
    cm::ContextManager, path::Union{Nothing, AbstractString, AbstractVector}=nothing
)
    if path === nothing
        @lock cm.lock begin
            return join(cm.current_path, cm.separator)
        end
    elseif path isa AbstractString
        return String(path)
    else
        return join(path, cm.separator)
    end
end

"""
    split_path(cm::ContextManager, path=nothing) -> Vector{String}

Split `path` (or current) into segments. Mirrors upstream `split_path`
(context_manager.py:135-148). Returns a **copy** of `current_path` when
`path === nothing`, not the live vector (departure from upstream — the
upstream aliasing was flagged as a hazard).
"""
function split_path(
    cm::ContextManager, path::Union{Nothing, AbstractString, AbstractVector}=nothing
)
    if path === nothing
        @lock cm.lock begin
            return copy(cm.current_path)
        end
    elseif path isa AbstractString
        isempty(path) && return String[]
        return String.(split(path, cm.separator))
    else
        return collect(String, path)
    end
end

"""
    append_path(cm::ContextManager; root=nothing, addition=nothing) -> String

Compute `<root>:<addition>` with edge-case handling. Mirrors upstream
`append_path` (context_manager.py:150-174).
"""
function append_path(cm::ContextManager;
    root::Union{Nothing, AbstractString, AbstractVector}=nothing,
    addition::Union{Nothing, AbstractString, AbstractVector}=nothing)
    if addition === nothing
        return join_path(cm, root)
    end
    root_str = join_path(cm, root)
    add_str = join_path(cm, addition)
    return isempty(root_str) ? add_str : string(root_str, cm.separator, add_str)
end

# ── Read accessors ────────────────────────────────────────────────────────────

"""
    current_path() -> String

Joined-string view of the current path stack. Empty string at root.
"""
current_path() = join_path(context_manager())

"""
    current_context() -> Union{AbstractContext, Nothing}

The `Context` registered at the current path, or `nothing` if none.
Mirrors upstream `current_context` property (context_manager.py:15-21).
"""
function current_context()
    cm = context_manager()
    @lock cm.lock begin
        return get(cm.contexts, join(cm.current_path, cm.separator), nothing)
    end
end

"""
    current_location() -> String

Last segment of the current path, or `""` at root. Mirrors upstream
`current_location` (context_manager.py:23-30).
"""
function current_location()
    cm = context_manager()
    @lock cm.lock begin
        return isempty(cm.current_path) ? "" : last(cm.current_path)
    end
end

"""
    get_context(path::AbstractString) -> Union{AbstractContext, Nothing}

Lookup by joined-string path. Mirrors upstream `get_context`
(context_manager.py:93-103).
"""
function get_context(path::AbstractString)
    cm = context_manager()
    @lock cm.lock begin
        return get(cm.contexts, String(path), nothing)
    end
end

"""
    context_exists(path::AbstractString) -> Bool

True if a Context is registered at `path`, OR if `path` is empty (the root
always "exists" per upstream context_manager.py:105-118).
"""
function context_exists(path::AbstractString)
    cm = context_manager()
    @lock cm.lock begin
        return isempty(path) || haskey(cm.contexts, String(path))
    end
end

# ── Mutation: stepping the current path ───────────────────────────────────────

"""
    step!(location::AbstractString; catch_empty::Bool=true) -> Bool

Push one segment onto the current path. Returns `true` iff a context exists
at the new path. With `catch_empty=true` (default), warns when stepping into
a non-existent context. Mirrors upstream `step` (context_manager.py:47-63).
"""
function step!(location::AbstractString; catch_empty::Bool=true)
    cm = context_manager()
    @lock cm.lock begin
        push!(cm.current_path, String(location))
        new_path = join(cm.current_path, cm.separator)
        exists = haskey(cm.contexts, new_path)
        if !exists && catch_empty
            ngc_warn("Context manager stepped into `", new_path,
                "` but no Context is registered there")
        end
        return exists
    end
end

"""
    step_back!() -> Bool

Pop one segment off the current path. Returns `false` at root (no-op).
Mirrors upstream `step_back` (context_manager.py:65-73).
"""
function step_back!()
    cm = context_manager()
    @lock cm.lock begin
        isempty(cm.current_path) && return false
        pop!(cm.current_path)
        return true
    end
end

"""
    step_to!(path::AbstractString) -> Bool

Replace `current_path` with `split_path(path)`. Returns `true` always
(matches upstream's `step_to` behavior at context_manager.py:91 — the
docstring claimed to return the existence flag but the code returns True
unconditionally; we keep faithful here and warn on missing).
"""
function step_to!(path::AbstractString)
    cm = context_manager()
    @lock cm.lock begin
        empty!(cm.current_path)
        if !isempty(path)
            append!(cm.current_path, String.(split(path, cm.separator)))
        end
        if !isempty(path) && !haskey(cm.contexts, String(path))
            ngc_warn("step_to!: no Context registered at `", path, "`")
        end
        return true
    end
end

# ── Registration ──────────────────────────────────────────────────────────────

"""
    register_context!(path::AbstractString, ctx::AbstractContext;
                       overwrite::Bool=false) -> Bool

Insert `ctx` into the global registry under `path`. With `overwrite=false`
(default), refuses to clobber an existing entry and emits a warn. Mirrors
upstream `register_context` (context_manager.py:176-197).
"""
function register_context!(path::AbstractString, ctx::AbstractContext;
    overwrite::Bool=false)
    cm = context_manager()
    @lock cm.lock begin
        if haskey(cm.contexts, String(path))
            if !overwrite
                ngc_warn("Context already registered at `", path, "`; not overwriting")
                return false
            else
                ngc_warn("Overwriting Context registered at `", path, "`")
            end
        end
        cm.contexts[String(path)] = ctx
        return true
    end
end

"""
    register_context_local!(local_path::AbstractString, ctx::AbstractContext;
                             overwrite::Bool=true) -> Bool

Register `ctx` at `<current_path>:<local_path>`. Note `overwrite=true` by
default (different from `register_context!`) — mirrors upstream's
asymmetric default at context_manager.py:199-213.
"""
function register_context_local!(local_path::AbstractString, ctx::AbstractContext;
    overwrite::Bool=true)
    cm = context_manager()
    full = append_path(cm; addition=local_path)
    return register_context!(full, ctx; overwrite=overwrite)
end

"""
    remove_context!(path::AbstractString) -> Bool

Delete the registration at `path`. Returns `true` if anything was removed.
Mirrors upstream `remove_context` (context_manager.py:215-232).
"""
function remove_context!(path::AbstractString)
    cm = context_manager()
    @lock cm.lock begin
        if haskey(cm.contexts, String(path))
            delete!(cm.contexts, String(path))
            return true
        end
        return false
    end
end

"""
    clear_contexts!()

Wipe every registered Context and reset the current path. Test/dev helper
mirroring upstream `clear` (context_manager.py:40-45).
"""
function clear_contexts!()
    cm = context_manager()
    @lock cm.lock begin
        empty!(cm.contexts)
        empty!(cm.current_path)
    end
    return nothing
end

export ContextManager, context_manager,
    current_path, current_context, current_location,
    get_context, context_exists,
    step!, step_back!, step_to!,
    register_context!, register_context_local!, remove_context!,
    clear_contexts!,
    join_path, split_path, append_path
