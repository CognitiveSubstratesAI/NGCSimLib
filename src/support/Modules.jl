# Modules.jl — port of ngcsimlib/_src/utils/modules.py
# Spec: docs/specs/06_support_spec.md §utils/modules.py (lines 641-728).
#
# Dynamic module / attribute discovery. Lets the user reference Julia types
# by string name and have them resolved at runtime from any already-loaded
# module. Upstream uses `importlib.import_module` + `sys.modules`; we use
# `Base.loaded_modules` for the discovery step.
#
# Two known semantics that MUST port 1:1 (spec lines 667-682):
#   1. Last-component module matching — `load_module("commands")` searches
#      all loaded modules for one whose name is `commands` (case-insensitive
#      by default).
#   2. First-char-uppercase attribute lookup —
#      `load_attribute("rateCell")` becomes a lookup for `RateCell`.
#      Does NOT lowercase the rest. Spec calls this "Port verbatim" (Open
#      Question #3).

# ── Caches (module-level, monotonically growing — same as upstream) ───────────

const _LOADED_MODULES    = Dict{String,Module}()
const _LOADED_ATTRIBUTES = Dict{String,Any}()

# Walk all reachable modules from `root`, including nested submodules.
# Used by load_module to emulate Python's `sys.modules` — any module that has
# been defined or imported anywhere is reachable from Main.
function _walk_modules(root::Module, seen::Set{Module})
    push!(seen, root)
    for nm in names(root; all=true, imported=false)
        # Skip noisy compiler-internal names
        startswith(string(nm), "#") && continue
        if isdefined(root, nm)
            child = try
                getfield(root, nm)
            catch
                continue
            end
            if child isa Module && !(child in seen)
                _walk_modules(child, seen)
            end
        end
    end
    return seen
end

# ── check_attributes ──────────────────────────────────────────────────────────

"""
    check_attributes(obj, required; fatal=false) -> Bool

For each `name` (Symbol or String) in `required`, verify `hasproperty(obj, name)`.
If `fatal=true` and a required name is missing, raises with a useful message;
otherwise returns `false`. `required === nothing` returns `true` immediately.

Mirrors upstream `check_attributes` (modules.py:10-40).
"""
function check_attributes(obj, required::Union{Nothing,AbstractVector}; fatal::Bool=false)
    required === nothing && return true
    objname = hasproperty(obj, :name) ? getproperty(obj, :name) : string(obj)
    for raw in required
        sym = raw isa Symbol ? raw : Symbol(raw)
        if !hasproperty(obj, sym)
            if fatal
                ngc_error(objname, " is missing required attribute `", sym, "`")
            else
                return false
            end
        end
    end
    return true
end

# ── load_module ───────────────────────────────────────────────────────────────

"""
    load_module(module_path; match_case=false, absolute_path=false) -> Module

Resolve a module by name. With `absolute_path=true`, treats `module_path`
as a registered package name and `Base.require`'s it. Otherwise scans
`Base.loaded_modules` for any module whose `nameof` matches the last
dot-component of `module_path` (case-insensitive by default).

Caches resolutions in `_LOADED_MODULES`. Raises an `ErrorException` (upstream
`RuntimeError`) on lookup failure. Mirrors upstream `load_module`
(modules.py:43-87).
"""
function load_module(module_path::AbstractString;
                     match_case::Bool=false,
                     absolute_path::Bool=false)
    haskey(_LOADED_MODULES, module_path) && return _LOADED_MODULES[module_path]

    mod::Union{Nothing,Module} = nothing
    if absolute_path
        # User opts in to "this is a registered package name".
        pkgid = Base.identify_package(String(module_path))
        pkgid === nothing && ngc_error("Failed to identify package \"", module_path, "\"")
        mod = Base.require(pkgid)
    else
        final = String(split(module_path, '.')[end])
        final_norm = match_case ? final : lowercase(final)
        # Search the union of (a) registered packages and (b) submodules
        # reachable from Main — matches Python `sys.modules` reach.
        candidates = Set{Module}()
        for m in values(Base.loaded_modules)
            push!(candidates, m)
        end
        _walk_modules(Main, candidates)
        for m in candidates
            last      = string(nameof(m))
            last_norm = match_case ? last : lowercase(last)
            if final_norm == last_norm
                ngc_info("Loading module from ", string(m))
                mod = m
                break
            end
        end
        mod === nothing &&
            ngc_error("Failed to find dynamic import for \"", module_path, "\"")
    end
    _LOADED_MODULES[module_path] = mod
    return mod
end

# ── load_attribute ────────────────────────────────────────────────────────────

"""
    load_attribute(attribute_name; module_path=nothing, match_case=false, absolute_path=false) -> Any

Resolve a named attribute (typically a type or function) from a module.

If `module_path === nothing`, uses `attribute_name` as the module name too.
If `match_case=false`, capitalises only the first letter of `attribute_name`
before `getfield` — so `load_attribute("rateCell")` looks up `RateCell`.
Does NOT lowercase the rest (spec Open Question #3 — port verbatim).

Caches in `_LOADED_ATTRIBUTES`. Raises on miss. Mirrors upstream
`load_attribute` (modules.py:120-165).
"""
function load_attribute(attribute_name::AbstractString;
                        module_path::Union{Nothing,AbstractString}=nothing,
                        match_case::Bool=false,
                        absolute_path::Bool=false)
    haskey(_LOADED_ATTRIBUTES, attribute_name) && return _LOADED_ATTRIBUTES[attribute_name]

    mp = module_path === nothing ? attribute_name : module_path
    mod = load_module(mp; match_case=match_case, absolute_path=absolute_path)

    name = if match_case
        attribute_name
    else
        isempty(attribute_name) ?
            ngc_error("load_attribute: attribute_name is empty") :
            string(uppercase(attribute_name[1:1]), attribute_name[nextind(attribute_name,1):end])
    end

    attr = try
        getfield(mod, Symbol(name))
    catch
        ngc_error("Could not find attribute \"", name, "\" in module ", nameof(mod))
    end

    _LOADED_ATTRIBUTES[attribute_name] = attr
    return attr
end

# ── load_from_path ────────────────────────────────────────────────────────────

"""
    load_from_path(path; match_case=false, absolute_path=false) -> Any

Convenience: when `absolute_path=true`, splits `path` on the **last** dot
into `module_name` (prefix) + `attribute_name` (suffix), then forces
`match_case=true` (preserves the exact spelling of the requested attribute).
Otherwise, treats the whole `path` as both module name and attribute name.

Mirrors upstream `load_from_path` (modules.py:90-117).
"""
function load_from_path(path::AbstractString;
                        match_case::Bool=false,
                        absolute_path::Bool=false)
    if absolute_path
        idx = findlast('.', path)
        if idx === nothing
            module_name = path
            attr_name   = path
        else
            module_name = String(path[1:prevind(path, idx)])
            attr_name   = String(path[nextind(path, idx):end])
        end
        return load_attribute(attr_name;
                              module_path  = module_name,
                              match_case   = true,
                              absolute_path= true)
    else
        return load_attribute(path;
                              module_path  = path,
                              match_case   = match_case,
                              absolute_path= false)
    end
end

# ── Test/dev helpers ──────────────────────────────────────────────────────────

"""
    reset_module_caches!()

Clear `_LOADED_MODULES` and `_LOADED_ATTRIBUTES`. Not in upstream surface;
needed for test isolation.
"""
function reset_module_caches!()
    empty!(_LOADED_MODULES)
    empty!(_LOADED_ATTRIBUTES)
    nothing
end

export check_attributes, load_module, load_attribute, load_from_path,
       reset_module_caches!
