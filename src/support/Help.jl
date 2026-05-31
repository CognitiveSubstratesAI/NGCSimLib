# Help.jl — port of ngcsimlib/_src/utils/help.py
# Spec: docs/specs/06_support_spec.md §utils/help.py (lines 731-800).
#
# Builds string documentation guides for component classes. A component
# implements a `help()` method returning a nested Dict; this module renders
# sections of that dict into human-readable strings.
#
# Upstream usage is purely end-user diagnostic — no internal runtime path
# depends on this. Low priority, but ported for surface parity.
#
# Open Question #2 in spec: upstream `help.py:89` has a trailing comma that
# makes `__monitoring` a 1-tuple. That's a real bug in upstream that throws
# on first use. We port the **intended** behavior (2-tuple) and flag in
# the docstring.

# ── Guide identifiers (enum-equivalent) ───────────────────────────────────────

"""
    GuideKind

Enum of guide identifiers exposed by `Guides`. Mirrors upstream
`GuideList(Enum)` (help.py:58-64). String values preserved for any user
code that pickle-style serialises by name.
"""
@enum GuideKind begin
    GuideInput
    GuideOutput
    GuideParameters
    GuideMonitoring
    GuideWiring
end

const _GUIDE_STR = Dict{GuideKind, String}(
    GuideInput => "input",
    GuideOutput => "output",
    GuideParameters => "params",
    GuideMonitoring => "monitoring",
    GuideWiring => "wiring"
)

guide_string(g::GuideKind) = _GUIDE_STR[g]

# ── Section renderers ─────────────────────────────────────────────────────────

# Descend a nested Dict along a `/`-separated path. Returns `nothing` if any
# step is missing — emulates upstream `data.get(part, None)` chain.
function _walk(data::Union{Nothing, AbstractDict}, section_path::AbstractString)
    cursor = data
    cursor === nothing && return nothing
    parts = split(section_path, '/'; keepempty=false)
    for p in parts
        if !(cursor isa AbstractDict)
            return nothing
        end
        sym_p = Symbol(p)
        cursor = if haskey(cursor, p)
            cursor[p]
        elseif haskey(cursor, sym_p)
            cursor[sym_p]
        else
            return nothing
        end
    end
    return cursor
end

"""
    _help_section(data, section_path, section_title, blank_msg; indent=1) -> String

Render a titled "section" of a help dict. Walks `data` along `section_path`
(slash-delimited). If the section is empty/missing:
  - Returns "" when `blank_msg == ""` (matches upstream short-circuit)
  - Returns `"<title>:\\n<indent><blank_msg>\\n"` otherwise.

Mirrors upstream `_HelpSection.write` (help.py:4-29).
"""
function _help_section(data, section_path::AbstractString,
    section_title::AbstractString,
    blank_msg::AbstractString;
    indent::Int=1)
    target = _walk(data, section_path)
    pad = "\t" ^ indent
    if target === nothing || (target isa AbstractDict && isempty(target))
        isempty(blank_msg) && return ""
        return string(section_title, ":\n", pad, blank_msg, "\n")
    end
    if !(target isa AbstractDict)
        # Leaf is a scalar / list — render it stringified.
        return string(section_title, ":\n", pad, target, "\n")
    end
    buf = IOBuffer()
    print(buf, section_title, ":\n")
    for (k, v) in target
        print(buf, pad, k, ": ", v, "\n")
    end
    return String(take!(buf))
end

# ── Static singleton section definitions ──────────────────────────────────────
# These mirror upstream module-level `_input_section`, `_output_section`,
# `_param_section` (help.py:45-55). Pure data — looked up by render_guide.

const _INPUT_SECTION = (
    "compartments/inputs", "Input Compartments", "There are no required inputs"
)
const _OUTPUT_SECTION = (
    "compartments/outputs", "Output Compartments", "There are no expected outputs"
)
const _PARAM_SECTION = (
    "hyperparameters", "Hyperparameters", "There are no required hyperparameters"
)

# ── Guide-level rendering ─────────────────────────────────────────────────────

# Per-guide static config: title + list of (path, title, blank) sections.
# Mirrors upstream `Guides.__inputs/__outputs/__params/__monitoring/__wiring`
# (help.py:84-90). NB: the trailing-comma bug on `__monitoring` is NOT ported —
# we render the same single section as upstream INTENDED (the output section).
const _GUIDE_CONFIG = Dict{GuideKind, Tuple{String, Vector{Tuple{String, String, String}}}}(
    GuideInput => ("Input Guide", [_INPUT_SECTION]),
    GuideOutput => ("Output Guide", [_OUTPUT_SECTION]),
    GuideParameters => ("Parameter Guide", [_PARAM_SECTION]),
    GuideMonitoring => ("Monitoring Guide", [_OUTPUT_SECTION]),
    GuideWiring => ("Wiring Guide", [_INPUT_SECTION, _OUTPUT_SECTION])
)

"""
    render_guide(data::AbstractDict, kind::GuideKind) -> String

Render one of the five canonical guides from a `data` dict produced by a
component's `help()` method. Mirrors upstream `Guides.__write_guide`
(help.py:111-123, called for each kind).
"""
function render_guide(data::AbstractDict, kind::GuideKind)
    (title, sections) = _GUIDE_CONFIG[kind]
    buf = IOBuffer()
    print(buf, title, "\n", "=" ^ length(title), "\n")
    for (path, sec_title, blank) in sections
        s = _help_section(data, path, sec_title, blank)
        isempty(s) || print(buf, s)
    end
    return String(take!(buf))
end

"""
    guides(data::AbstractDict) -> NamedTuple

Render all five guides at once, returning a `NamedTuple` for dot-access.
Mirrors upstream `Guides(base_cls)` constructor (help.py:67-110), which
populates `self.inputs`, `self.outputs`, `self.monitoring`, `self.params`,
`self.wiring`.
"""
function guides(data::AbstractDict)
    return (
        inputs=render_guide(data, GuideInput),
        outputs=render_guide(data, GuideOutput),
        params=render_guide(data, GuideParameters),
        monitoring=render_guide(data, GuideMonitoring),
        wiring=render_guide(data, GuideWiring)
    )
end

export GuideKind, GuideInput, GuideOutput, GuideParameters, GuideMonitoring,
    GuideWiring, guide_string, render_guide, guides
