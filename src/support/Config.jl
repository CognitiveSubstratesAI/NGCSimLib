# Config.jl — port of ngcsimlib/_src/configManager.py
# Spec: docs/specs/06_support_spec.md §configManager.py (lines 243-306).
#
# A JSON-file-backed singleton. No schema, no validation: whatever JSON loads
# is stashed verbatim and consumers ask for top-level keys by name.
#
# Two known consumers upstream:
#   - logger.init_logging reads section "logging"
#   - the (dead) preload_modules path read section "modules"
#
# Format MUST stay JSON (not TOML) — preserves cross-language artifact compat
# with the upstream Python lib.

using JSON3

# ── Singleton state ───────────────────────────────────────────────────────────

# `nothing` until init_config() is called. Mirrors upstream loadedConfig=None.
const _LOADED_CONFIG = Ref{Union{Nothing,Dict{String,Any}}}(nothing)

# ── Public API ────────────────────────────────────────────────────────────────

"""
    init_config(path::AbstractString) -> Nothing

Read a JSON file from `path` and stash it as the global config dict.
Mirrors upstream `init_config` (configManager.py:14-16). Throws on missing
file or JSON parse error — upstream does too (no try/except wrap).
"""
function init_config(path::AbstractString)
    _LOADED_CONFIG[] = Dict{String,Any}(JSON3.read(read(path, String), Dict{String,Any}))
    return nothing
end

"""
    get_config(name::AbstractString) -> Union{Any, Nothing}

Returns `loadedConfig[name]` or `nothing` if (a) `init_config` was never
called, or (b) the key is absent. Mirrors upstream `get_config`
(configManager.py:18-25). Two guards, both return `None` silently.
"""
function get_config(name::AbstractString)
    cfg = _LOADED_CONFIG[]
    cfg === nothing && return nothing
    return get(cfg, name, nothing)
end

"""
    provide_namespace(name::AbstractString) -> Union{NamedTuple, Nothing}

Returns the section as a `NamedTuple` for dot-access (`cfg.logging_level`),
or `nothing` if the section is absent. Mirrors upstream `provide_namespace`
which wraps the dict in `types.SimpleNamespace` (configManager.py:27-32).
"""
function provide_namespace(name::AbstractString)
    cfg = get_config(name)
    cfg === nothing && return nothing
    # JSON3 may return Dict{String,Any} or an ordered subtype; normalize.
    d = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in cfg)
    return NamedTuple{Tuple(keys(d))}(values(d))
end

"""
    reset_config!() -> Nothing

Test helper: clears the singleton. Not in upstream surface but needed
because Julia tests share module state across testsets.
"""
function reset_config!()
    _LOADED_CONFIG[] = nothing
    return nothing
end

export init_config, get_config, provide_namespace, reset_config!
