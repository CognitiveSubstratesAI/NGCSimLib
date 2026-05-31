# MethodProcess.jl — port of ngcsimlib/_src/process/methodProcess.py
# Spec: docs/specs/03_process_spec.md §"MethodProcess".
#
# Records an ordered list of `(component_instance, method_name)` steps and
# splices their @compilable bodies into one runner function via
# `compile_process!` (inherited from BaseProcess.jl).
#
# Chaining API:
#   then!(p, c, :method)        — explicit form
#   p >> (c, :method)           — operator form
#   p >> [(c1, :m1), (c2, :m2)] — vectorised
#
# Upstream uses Python's bound-method `.method` syntax (`p >> c.method`).
# Julia doesn't have that — methods aren't attribute lookups — so we accept
# tuples `(c, :method_sym)` instead.

# ── The MethodProcess type ────────────────────────────────────────────────────

"""
    MethodProcess

A concrete `AbstractProcess` that records ordered `(component, method)` steps
and compiles them into a single pure function via `compile_process!`.

Construct via `MethodProcess(name="…")`. Chain steps via [`then!`](@ref)
or the `>>` operator.
"""
mutable struct MethodProcess <: AbstractProcess
    name::String
    context_path::String
    args::Vector{Any}
    kwargs::Dict{Symbol,Any}
    keyword_order::Vector{Symbol}
    watch_list::Vector{Compartment}
    method_order::Vector{Tuple{AbstractComponent,Symbol}}
    # `compiled` holds a `CompiledRunner` (callable wrapper around either a
    # Julia closure for the eager path or a `Reactant.Compiler.Thunk` from
    # `compile_with_reactant!`). See BaseProcess.jl for the wrapper rationale.
    compiled::Union{Nothing,CompiledRunner}
end

"""
    MethodProcess(; name::AbstractString) -> MethodProcess

Construct an empty MethodProcess. Caller adds steps via [`then!`](@ref) or
`>>`, then triggers [`compile_process!`](@ref) (or closes the enclosing
Context block, which calls `recompile!` on every registered Process).
"""
function MethodProcess(; name::AbstractString)
    return MethodProcess(
        String(name),
        "",                                       # context_path filled by post_init!
        Any[],
        Dict{Symbol,Any}(),
        Symbol[],
        Compartment[],
        Tuple{AbstractComponent,Symbol}[],
        nothing,
    )
end

# ── Chaining ──────────────────────────────────────────────────────────────────

"""
    then!(p::MethodProcess, c::AbstractComponent, method_name::Symbol) -> p

Append `(c, method_name)` to the method order. The method must have been
defined with `@compilable` on the receiver type. Mirrors upstream
`MethodProcess.then` (methodProcess.py:38-47).
"""
function then!(p::MethodProcess, c::AbstractComponent, method_name::Symbol)
    is_compilable_method(typeof(c), method_name) ||
        ngc_error("then!: method `", method_name, "` is not @compilable on ",
                  typeof(c))
    push!(p.method_order, (c, method_name))
    return p
end

# Tuple-form for symmetry with the `>>` operator
then!(p::MethodProcess, step::Tuple{AbstractComponent,Symbol}) =
    then!(p, step[1], step[2])

# `>>` operator (mirrors upstream `MethodProcess.__rshift__` — methodProcess.py:49-50)
Base.:(>>)(p::MethodProcess, step::Tuple{AbstractComponent,Symbol}) =
    then!(p, step)

# Vectorised: `p >> [(c1, :m1), (c2, :m2)]`
function Base.:(>>)(p::MethodProcess, steps::AbstractVector{<:Tuple{AbstractComponent,Symbol}})
    for s in steps
        then!(p, s)
    end
    return p
end

# ── _parse! (consumed by compile_process! in BaseProcess.jl) ──────────────────

"""
    _parse!(p::MethodProcess) -> Vector{Tuple{AbstractComponent, Symbol}}

Return the step list. Side effect: every component's `@compilable` methods
get lazy-compiled inside `compile_process!` (via `get_compiled`). Mirrors
upstream `MethodProcess._parse` (methodProcess.py:52-75).
"""
_parse!(p::MethodProcess) = p.method_order

# ── Display ───────────────────────────────────────────────────────────────────

function Base.show(io::IO, p::MethodProcess)
    print(io, "MethodProcess(name=\"", p.name,
          "\", steps=", length(p.method_order),
          ", compiled=", is_compiled(p), ")")
end

export MethodProcess, then!
