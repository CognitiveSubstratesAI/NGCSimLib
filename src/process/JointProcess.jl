# JointProcess.jl — port of ngcsimlib/_src/process/jointProcess.py
# Spec: docs/specs/03_process_spec.md §"JointProcess".
#
# A JointProcess is a Process whose units are OTHER Processes rather than
# component methods. Compiling it produces a single runner that calls each
# sub-process's runner sequentially, threading ctx through.
#
# Priority bias: each `then!` lowers the JointProcess's own priority below
# the lowest sub-process priority, so JointProcesses always compile *after*
# their constituents (spec jointProcess.py:17-18).

# ── The JointProcess type ─────────────────────────────────────────────────────

"""
    JointProcess

A concrete `AbstractProcess` that records ordered sub-processes and runs
them in sequence. Priority is biased lower-than-lowest-sub on each `then!`
so it always compiles after its sub-processes.
"""
mutable struct JointProcess <: AbstractProcess
    name::String
    context_path::String
    args::Vector{Any}
    kwargs::Dict{Symbol,Any}
    keyword_order::Vector{Symbol}
    watch_list::Vector{Compartment}
    process_order::Vector{AbstractProcess}
    compiled::Union{Nothing,CompiledRunner}   # see BaseProcess.CompiledRunner
end

"""
    JointProcess(; name::AbstractString) -> JointProcess

Construct an empty JointProcess. Add sub-processes via `then!(jp, p)` or
`jp >> p`.
"""
function JointProcess(; name::AbstractString)
    jp = JointProcess(
        String(name),
        "",
        Any[],
        Dict{Symbol,Any}(),
        Symbol[],
        Compartment[],
        AbstractProcess[],
        nothing,
    )
    # JointProcess starts at priority -1 (matches upstream
    # `@priority(-1)` on BaseProcess; jointProcess.py:14 inherits and uses it).
    priority!(jp, -1)
    return jp
end

# ── Chaining ──────────────────────────────────────────────────────────────────

"""
    then!(jp::JointProcess, sub::AbstractProcess) -> jp

Append `sub` to the joint's order. Adjusts `jp`'s priority to `sub.priority - 1`
if necessary so the joint always compiles after its newest sub. Mirrors
upstream `JointProcess.then` (jointProcess.py:16-22).
"""
function then!(jp::JointProcess, sub::AbstractProcess)
    sub_pri = get_priority(sub)
    jp_pri  = get_priority(jp)
    if sub_pri <= jp_pri
        priority!(jp, sub_pri - 1)
    end
    push!(jp.process_order, sub)
    return jp
end

Base.:(>>)(jp::JointProcess, sub::AbstractProcess) = then!(jp, sub)

function Base.:(>>)(jp::JointProcess, subs::AbstractVector{<:AbstractProcess})
    for s in subs
        then!(jp, s)
    end
    return jp
end

# ── _parse! ───────────────────────────────────────────────────────────────────

"""
    _parse!(jp::JointProcess) -> Vector{Tuple{AbstractComponent, Symbol}}

Flatten the joint's sub-processes into a single step list. Each sub-process
contributes its own `_parse!` result; the union of all kwargs propagates
to `jp.keyword_order` (handled by `compile_process!` in BaseProcess.jl).

The watch_list of each sub-process is merged into `jp.watch_list` (mirrors
upstream's mutation at jointProcess.py:53-57).

Mirrors upstream `JointProcess._parse` (jointProcess.py:26-60).
"""
function _parse!(jp::JointProcess)
    steps = Tuple{AbstractComponent,Symbol}[]
    joint_watch = Compartment[]
    for sub in jp.process_order
        append!(steps, _parse!(sub))
        append!(joint_watch, sub.watch_list)
    end
    append!(joint_watch, jp.watch_list)
    # Dedupe — preserve first-occurrence order.
    seen = Set{Compartment}()
    deduped = Compartment[]
    for c in joint_watch
        if !(c in seen)
            push!(deduped, c)
            push!(seen, c)
        end
    end
    empty!(jp.watch_list)
    append!(jp.watch_list, deduped)
    return steps
end

# ── Display ───────────────────────────────────────────────────────────────────

function Base.show(io::IO, jp::JointProcess)
    print(io, "JointProcess(name=\"", jp.name,
          "\", subs=", length(jp.process_order),
          ", compiled=", is_compiled(jp), ")")
end

export JointProcess
