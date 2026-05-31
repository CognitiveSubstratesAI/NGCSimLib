# IO.jl — port of ngcsimlib/_src/utils/io.py
# Spec: docs/specs/06_support_spec.md §utils/io.py (lines 529-582).
#
# Three filesystem / serialization helpers. Used by `_src/context/context.py`
# at lines 5,247,261,270,324 to build per-model save directories with safe,
# unique names.
#
# Hazard note (Open question #10 in spec): upstream uses `print(...)`, not
# `logger.info(...)`. So `hide_console=True` in logging config does NOT
# suppress these messages. Port verbatim with `println(...)`. Flagged for
# Phase B hardening if/when clean-output users complain.

using UUIDs
using JSON3

# ── Public API ────────────────────────────────────────────────────────────────

"""
    make_safe_filename(name; replacement="_") -> String

Sanitize `name` for use as a filename. Replaces spaces and any of
`<>:"/\\|?*` plus ASCII control chars `\\x00-\\x1F` with `replacement`,
then trims trailing whitespace.

Mirrors upstream regex `r'[ <>:"/\\\\|?*\\0-\\31]'` (io.py:3-5).
"""
function make_safe_filename(name::AbstractString; replacement::AbstractString="_")
    # First-pass: replace spaces (preserves upstream two-stage semantics —
    # space is in the character class too, so this is redundant but matches
    # upstream code structure exactly).
    s = replace(name, ' ' => replacement)
    # Second-pass: control chars + filesystem-reserved punctuation.
    s = replace(s, r"[ <>:\"/\\|?*\x00-\x1F]" => replacement)
    return String(strip(s))
end

"""
    make_unique_path(directory, root_name=nothing) -> String

Generate (and `mkdir`) a unique subdirectory under `directory`. If
`root_name === nothing`, names it with a fresh UUIDv4. If `root_name` is
given but `directory/root_name` already exists, appends `_<uuid4>`.

Returns the new path. Mirrors upstream `make_unique_path` (io.py:7-34).

**Side effect**: `println` (NOT logger) reports the chosen name. This matches
upstream behaviour — see Open Question #10 in the support spec.
"""
function make_unique_path(directory::AbstractString,
                          root_name::Union{Nothing,AbstractString}=nothing)
    if root_name === nothing
        root_name = string(uuid4())
        println("generated path will be named \"", root_name, "\"")
    elseif isdir(joinpath(directory, root_name))
        root_name = string(root_name, "_", uuid4())
        println("root path already exists, generated path will be named \"",
                root_name, "\"")
    end
    path = joinpath(directory, root_name)
    mkdir(path)
    return path
end

"""
    check_serializable(d::AbstractDict) -> Vector{String}

Returns the keys of `d` whose values cannot be JSON-encoded via `JSON3.write`.
Mirrors upstream `check_serializable` (io.py:37-53), which catches the
`TypeError` from `json.dumps`. No internal callers — exists for user code that
wants to pre-validate save payloads.
"""
function check_serializable(d::AbstractDict)
    bad = String[]
    for (k, v) in d
        try
            JSON3.write(v)
        catch
            push!(bad, string(k))
        end
    end
    return bad
end

export make_safe_filename, make_unique_path, check_serializable
