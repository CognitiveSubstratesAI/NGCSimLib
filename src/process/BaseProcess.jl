# BaseProcess.jl — port of ngcsimlib/_src/process/baseProcess.py
# Spec: docs/specs/03_process_spec.md §"BaseProcess".
#
# A Process is an ordered sequence of `(component, method_name)` steps that
# get compiled into a pure function `(ctx::Dict, kwargs...) → (ctx, watched_tuple)`.
#
# `compile_process!` produces a Julia-eager runner (works without Reactant).
# `compile_with_reactant!` (opt-in) wraps that runner with `Reactant.@compile`
# for traced JIT execution — validated end-to-end against the Parser output
# in 2026-05-31 spike (decisions.md #9).

import Reactant

# ── CompiledRunner: opaque callable wrapper ───────────────────────────────────
#
# Holds either a Julia closure (eager) or a `Reactant.Compiler.Thunk` (JIT)
# behind a single concrete type. This keeps `Any` out of struct signatures —
# the heterogeneity is encapsulated in `payload`, with one well-known
# dispatch entry point.
#
# Why not `Union{Nothing,Function,Reactant.Compiler.Thunk}`? `Compiler.Thunk`
# is a Reactant *internal* — naming it in our struct ties us to Reactant's
# unstable surface. The wrapper is refactor-tolerant.
#
# Why not `<: Function`? Reactant.Thunk doesn't subtype Function; Julia has
# no `AbstractCallable` supertype, only the implicit "supports
# `(::T)(args...)`" protocol.

"""
    CompiledRunner

Opaque callable: wraps the result of `compile_process!` (Julia closure) or
`compile_with_reactant!` (`Reactant.Compiler.Thunk`). Stored on
`AbstractProcess.compiled` as `Union{Nothing, CompiledRunner}`. Dispatch
through `(::CompiledRunner)(args...)` forwards to the inner payload.
"""
struct CompiledRunner
    payload::Any
end

(r::CompiledRunner)(args...; kwargs...) = r.payload(args...; kwargs...)

Base.show(io::IO, r::CompiledRunner) =
    print(io, "CompiledRunner(", nameof(typeof(r.payload)), ")")
#
# AbstractProcess is declared in AbstractTypes.jl. Concrete process types
# (MethodProcess, JointProcess) subtype it and provide their own `_parse!`
# which fills `keyword_order`/`watch_list` + builds the spliced body.
#
# Phase A scope:
#   - keyword_order  — list of kwarg names (Symbol) gathered from all methods
#   - watch_list     — Compartments whose final values get returned alongside ctx
#   - run            — eager runner that walks `_parse!`'d step list
#   - is_compiled?   — true after compile_process! ran
#   - compile_process! — builds the spliced runner and stashes it as `compiled`
#
# Phase B will add:
#   - Reactant.@compile of the spliced runner
#   - from_json / to_json serialization
#   - JointProcess priority bias (already noted in spec)

# ── BaseProcess interface ─────────────────────────────────────────────────────
# Concrete subtypes MUST expose these fields:
#   - name::String
#   - context_path::String
#   - args::Vector{Any}
#   - kwargs::Dict{Symbol,Any}
#   - keyword_order::Vector{Symbol}
#   - watch_list::Vector{Compartment}
#   - compiled::Union{Nothing, Function}
#
# Concrete subtypes MUST implement:
#   - _parse!(p::ConcreteProcess) -> Vector{Tuple{AbstractComponent, Symbol}}
#     returning the ordered (instance, method_name) step list and populating
#     `p.keyword_order` as a side effect (union of every step's kwargs)

# ── Accessors ─────────────────────────────────────────────────────────────────

"""
    watch_list(p::AbstractProcess) -> Vector{Compartment}

Compartments whose final values are returned (as a tuple) alongside the
mutated ctx. Mirrors upstream `_watch_list` (baseProcess.py:62).
"""
watch_list(p::AbstractProcess) = p.watch_list

"""
    keyword_order(p::AbstractProcess) -> Vector{Symbol}

Ordered list of kwarg names this process expects at `run` time. Populated
during `compile_process!` from the union of each step's parser-detected
kwargs. Mirrors upstream `_keyword_order` (baseProcess.py:65).
"""
keyword_order(p::AbstractProcess) = p.keyword_order

"""
    is_compiled(p::AbstractProcess) -> Bool

True if `compile_process!` has populated `p.compiled`. Mirrors upstream
`is_compiled` (baseProcess.py:108-109).
"""
is_compiled(p::AbstractProcess) = p.compiled !== nothing

# ── watch! ────────────────────────────────────────────────────────────────────

"""
    watch!(p::AbstractProcess, compartments::Compartment...) -> p

Mark each `compartment` for inclusion in the watched-tuple returned by
`run`. Mirrors upstream `BaseProcess.watch` (baseProcess.py:38-46).
"""
function watch!(p::AbstractProcess, compartments::Compartment...)
    for c in compartments
        push!(p.watch_list, c)
    end
    return p
end

# ── pack_keywords ─────────────────────────────────────────────────────────────

"""
    pack_keywords(p::AbstractProcess; row_seed=nothing, kwargs...) -> Vector

For each key in `p.keyword_order`, pick `kwargs[key]`. If the value is a
callable, call it with `row_seed` (which must be given). Returns a `Vector`
in `keyword_order` order. Mirrors upstream `pack_keywords`
(baseProcess.py:56-86).
"""
function pack_keywords(p::AbstractProcess; row_seed=nothing, kwargs...)
    out = Any[]
    for key in p.keyword_order
        haskey(kwargs, key) ||
            ngc_error("pack_keywords: missing required key `", key, "`")
        v = kwargs[key]
        if v isa Function
            row_seed === nothing &&
                ngc_error("pack_keywords: key `", key,
                    "` is callable but no row_seed was provided")
            push!(out, v(row_seed))
        else
            push!(out, v)
        end
    end
    return out
end

"""
    pack_rows(p::AbstractProcess, length::Integer;
              seed_generator=identity, kwargs...) -> Vector{Vector}

Produce `length` rows, each generated via `pack_keywords(p; row_seed=seed_generator(i), kwargs...)`.
Mirrors upstream `pack_rows` (baseProcess.py:88-106).
"""
function pack_rows(p::AbstractProcess, length::Integer;
    seed_generator=identity, kwargs...)
    return [pack_keywords(p; row_seed=seed_generator(i), kwargs...) for i in 1:length]
end

# ── run ───────────────────────────────────────────────────────────────────────

"""
    run(p::AbstractProcess; state=nothing, keywords=nothing,
                            update::Bool=true, row_seed=nothing,
                            kwargs...) -> (ctx, watched)

Execute the compiled process. Mirrors upstream `BaseProcess.run`
(baseProcess.py:111-144).

Defaults:
  - `state=nothing`     → use `get_state()` snapshot of the global manager
  - `keywords=nothing`  → call `pack_keywords(p; row_seed=row_seed, kwargs...)`
  - `update=true`       → write the mutated ctx back via `set_state!`

Throws if not yet compiled.
"""
function run(p::AbstractProcess;
    state::Union{Nothing, AbstractDict}=nothing,
    keywords::Union{Nothing, AbstractVector}=nothing,
    update::Bool=true,
    row_seed=nothing,
    kwargs...)
    is_compiled(p) ||
        ngc_error("run: process `", p.name,
            "` has not been compiled — call compile_process!(p) or finish",
            " the enclosing Context block first")
    ctx = state === nothing ? get_state() : state
    kw = keywords === nothing ? pack_keywords(p; row_seed=row_seed, kwargs...) : keywords
    new_ctx, watched = p.compiled(ctx, kw)
    if update
        set_state!(new_ctx)
    end
    return new_ctx, watched
end

# ── compile_process! ──────────────────────────────────────────────────────────

"""
    compile_process!(p::AbstractProcess) -> p

Walk the process's step list (via `_parse!`), compile every component's
`@compilable` methods, gather the union of their needed kwargs into
`p.keyword_order`, and synthesize the spliced runner function as `p.compiled`.

Phase A: the runner is a plain Julia closure that calls each step
sequentially. Phase B will replace with a Reactant-traced one.

Mirrors upstream `BaseProcess.compile` (baseProcess.py:150-209), but
emits a closure rather than an AST + exec.
"""
function compile_process!(p::AbstractProcess)
    steps = _parse!(p)
    # Ensure every component is parsed at least once so each step has a
    # CompiledMethod entry in the cache.
    for (c, m) in steps
        get_compiled(c, m)
    end

    # Collect the union of kwarg names every step needs. The Parser promotes
    # original positional args (after receiver) to required kwargs in the
    # rewritten signature, so a single kwargs-only dispatch path covers both
    # originally-positional and originally-kwarg cases.
    kw_set = Set{Symbol}()
    for (c, m) in steps
        cm = get_compiled(c, m)
        union!(kw_set, cm.signature_kwargs)
    end
    empty!(p.keyword_order)
    append!(p.keyword_order, sort(collect(kw_set)))

    # Snapshot the watch_list at compile time so the runner is closed
    # over a stable Vector.
    watched = copy(p.watch_list)

    # Pre-bake each step's kwarg name list so the runner doesn't rebuild it
    # from `signature_kwargs` on every call.
    step_kwargs = [Tuple(get_compiled(c, m).signature_kwargs) for (c, m) in steps]
    keyword_order_local = copy(p.keyword_order)

    # Sequential runner — pure function over (ctx, loop_args).
    # `loop_args` is the Vector of values in `keyword_order` order.
    eager_runner =
        (ctx::AbstractDict, loop_args::AbstractVector) -> begin
            # Build the per-call name → value map once.
            kw_pairs = Pair{Symbol, Any}[]
            for (i, k) in enumerate(keyword_order_local)
                push!(kw_pairs, k => loop_args[i])
            end
            kw_full = Dict{Symbol, Any}(kw_pairs)

            out_ctx = ctx
            for (si, (c, m)) in enumerate(steps)
                cm = get_compiled(c, m)
                # Pass only the kwargs this step's signature actually accepts.
                step_kw = (; (k => kw_full[k] for k in step_kwargs[si])...)
                out_ctx = cm.fn(out_ctx; step_kw...)
            end
            # Watched tuple: final values of every compartment in watch_list
            watched_vals = Tuple(out_ctx[w.root_target] for w in watched)
            return (out_ctx, watched_vals)
        end
    p.compiled = CompiledRunner(eager_runner)

    return p
end

# ── compile_with_reactant! (opt-in JIT) ───────────────────────────────────────

"""
    compile_with_reactant!(p::AbstractProcess,
                           sample_ctx::AbstractDict,
                           sample_loop_args::AbstractVector) -> p

Replace `p.compiled` (a Julia-eager closure) with a `Reactant.@compile`'d
traced version. The sample inputs determine the shapes / types Reactant
traces against — every subsequent `run()` call must use compatible
shapes (per Reactant's tracing model).

If `compile_process!` hasn't been called yet, this triggers it first.

Validated by decisions.md #9 — Reactant 0.2.262 traces through
`Dict{String,Any}` ctx with string-keyed access as constants. No Parser
rewrite required.

Throws on first-call shape mismatch. To recompile against different
shapes, call `compile_process!(p)` (reverts to eager) then re-run this.
"""
function compile_with_reactant!(p::AbstractProcess,
    sample_ctx::AbstractDict,
    sample_loop_args::AbstractVector)
    is_compiled(p) || compile_process!(p)
    eager_runner = p.compiled   # CompiledRunner wrapping the eager closure
    # `@compile` is a Reactant macro — it expands at parse time using the
    # local `eager_runner` / sample inputs to determine tracing arguments.
    # The result is a Reactant.Compiler.Thunk; rewrap in CompiledRunner.
    thunk = Reactant.@compile eager_runner(sample_ctx, sample_loop_args)
    p.compiled = CompiledRunner(thunk)
    return p
end

# ── view_compiled ─────────────────────────────────────────────────────────────

"""
    view_compiled(p::AbstractProcess) -> String

Return a human-readable view of the compiled runner. Phase A: lists the
step sequence + kwargs + watched. Phase B: emit the full spliced Expr.

Mirrors upstream `view_compiled_method` (baseProcess.py:28-35).
"""
function view_compiled(p::AbstractProcess)
    is_compiled(p) || return "Not Compiled"
    buf = IOBuffer()
    println(buf, "Process: ", p.name)
    println(buf, "  keyword_order: ", p.keyword_order)
    println(buf, "  watched: ", [w.root_target for w in p.watch_list])
    println(buf, "  steps:")
    for (i, (c, m)) in enumerate(_parse!(p))
        println(buf, "    [", i, "] ", typeof(c), "(`", c.name, "`).", m)
    end
    return String(take!(buf))
end

# ── post_init! extension for AbstractProcess ──────────────────────────────────
# A Process registers itself in the enclosing Context (under the PROCESS
# bucket) just like a Component, but it has no Compartment fields to setup.

function post_init!(p::AbstractProcess)
    cp = current_path()
    if isempty(p.context_path)
        p.context_path = cp
    end
    ctx = current_context()
    if ctx !== nothing
        register_obj!(ctx, p)
    end
    return p
end

export AbstractProcess, CompiledRunner,
    watch_list, keyword_order, is_compiled,
    watch!, pack_keywords, pack_rows,
    run, compile_process!, compile_with_reactant!, view_compiled
