# Logger.jl — port of ngcsimlib/_src/logger.py
# Spec: docs/specs/06_support_spec.md §logger.py (lines 143-239).
#
# Wraps Julia's stdlib Logging with the ngcsimlib conventions:
#   - print-style varargs (joined by space)
#   - ngc_error / ngc_critical RAISE (control flow, not fire-and-forget logging)
#   - runtime-extensible custom log levels
#   - singleton named logger backed by Logging.AbstractLogger
#
# Public names are `ngc_warn` / `ngc_info` / `ngc_debug` / `ngc_error` / `ngc_critical`
# rather than `warn` / `error` / etc. to avoid shadowing `Base.error` and
# `Base.warn`. Per design doc §9 (Public API).

using Logging
using Dates

# ── Module-level singleton state ──────────────────────────────────────────────

# Custom log levels installed at runtime via add_logging_level. Keyed by both
# Symbol and Int so callers can look up either way (mirrors upstream
# _mapped_calls indexed by both name and number).
const _CUSTOM_LEVELS = Dict{Union{Symbol, Int}, Logging.LogLevel}()

# Replaceable logger slot. Wrapping in a mutable struct lets `init_logging()`
# swap the logger wholesale while `OncePerProcess` handles the one-shot,
# precompile-safe, lazy construction of the default.
#
# Why not capture `stderr` directly in a `const Ref` at module-load?
# `stderr` is invalid in the precompile context — its handle is stashed in
# the `.ji` file and triggers `ArgumentError: stream not initialized` on
# first load. `OncePerProcess` defers construction until first call,
# guaranteeing a valid stderr.
mutable struct _LoggerSlot
    logger::Logging.AbstractLogger
end

const _NGC_LOGGER = OncePerProcess{_LoggerSlot}() do
    _LoggerSlot(Logging.ConsoleLogger(stderr, Logging.Error))
end

# Default configuration knobs (mirror upstream lines 73-77).
const _DEFAULT_LOG_LEVEL = Logging.Error
const _DEFAULT_HIDE_CONSOLE = false

# ── Private helpers ───────────────────────────────────────────────────────────

# Join varargs print-style. Mirrors upstream _concatArgs decorator (lines 7-14).
@inline _concat_args(args...; sep::AbstractString=" ", finish::AbstractString="") =
    string(join(string.(args), sep), finish)

# Emit one log record to the configured logger. `_NGC_LOGGER()` lazily
# constructs the default `_LoggerSlot` on first call (post-precompile),
# then returns the same slot every time — so swaps via `init_logging`
# are seen by all callers immediately.
@inline function _emit(level::Logging.LogLevel, msg::AbstractString)
    Logging.with_logger(_NGC_LOGGER().logger) do
        @logmsg level msg
    end
    nothing
end

# ── Public log functions (matching upstream surface) ──────────────────────────

"""
    ngc_warn(args...; sep=" ", finish="")

Log a warning. Does NOT raise. Args are joined with `sep` (default `" "`)
mirroring Python `print`. Equivalent to upstream `warn()` (logger.py:108-118).
"""
ngc_warn(args...; sep::AbstractString=" ", finish::AbstractString="") =
    _emit(Logging.Warn, _concat_args(args...; sep=sep, finish=finish))

"""
    ngc_info(args...; sep=" ", finish="")

Log an info message. Does NOT raise.
Equivalent to upstream `info()` (logger.py:150-160).
"""
ngc_info(args...; sep::AbstractString=" ", finish::AbstractString="") =
    _emit(Logging.Info, _concat_args(args...; sep=sep, finish=finish))

"""
    ngc_debug(args...; sep=" ", finish="")

Log a debug message. Does NOT raise.
Equivalent to upstream `debug()` (logger.py:163-173).
"""
ngc_debug(args...; sep::AbstractString=" ", finish::AbstractString="") =
    _emit(Logging.Debug, _concat_args(args...; sep=sep, finish=finish))

"""
    ngc_error(args...; errortype::Type{<:Exception}=ErrorException, sep=" ", finish="")

Log at Error level THEN `throw(errortype(msg))`. **This is control flow** — callers
expect it to abort the current execution path. Mirrors upstream `error()` exactly
(logger.py:121-133), preserving the raise-on-error semantic that the rest of
ngcsimlib depends on.

Different from `Base.error` only in that it also emits a log record before
the throw.
"""
function ngc_error(args...;
    errortype::Type{<:Exception}=ErrorException,
    sep::AbstractString=" ",
    finish::AbstractString="")
    msg = _concat_args(args...; sep=sep, finish=finish)
    _emit(Logging.Error, msg)
    throw(errortype(msg))
end

"""
    ngc_critical(args...; sep=" ", finish="")

Log at Critical level (custom LogLevel 2000, above Error) THEN throw an
`ErrorException`. **Control flow.** Mirrors upstream `critical()` (logger.py:136-147)
which always raises `RuntimeError` regardless of caller intent — the
`errortype` knob is intentionally NOT exposed here (matching upstream behavior).
"""
function ngc_critical(args...; sep::AbstractString=" ", finish::AbstractString="")
    msg = _concat_args(args...; sep=sep, finish=finish)
    _emit(Logging.LogLevel(2000), msg)
    throw(ErrorException(msg))
end

# ── Custom log levels (runtime-extensible) ────────────────────────────────────

"""
    add_logging_level(name::Union{Symbol,AbstractString}, num::Integer)

Register a custom log level. Subsequent calls to `custom_log(msg, name)` or
`custom_log(msg, num)` dispatch to a `LogLevel(num)` emission. Mirrors upstream
`addLoggingLevel` (logger.py:22-69) but does NOT monkey-patch the stdlib
`Logging` module — Julia's LogLevel is a value type, no global state to mutate.

Throws if `name` collides with an already-registered Symbol.
"""
function add_logging_level(name::Union{Symbol, AbstractString}, num::Integer)
    sym = name isa Symbol ? name : Symbol(name)
    haskey(_CUSTOM_LEVELS, sym) &&
        ngc_error("custom logging level `", sym, "` already registered")
    lvl = Logging.LogLevel(Int(num))
    _CUSTOM_LEVELS[sym] = lvl
    _CUSTOM_LEVELS[Int(num)] = lvl
    nothing
end

"""
    custom_log(msg::AbstractString, level::Union{Symbol,AbstractString,Integer,Nothing}=nothing)

Emit `msg` at the previously-registered custom `level`. If `level === nothing`
or unregistered, emits a warning and skips (matches upstream `custom_log`
lines 176-204).
"""
function custom_log(msg::AbstractString,
    level::Union{Symbol, AbstractString, Integer, Nothing}=nothing)
    if level === nothing
        ngc_warn("custom_log: no level supplied; skipping `", msg, "`")
        return nothing
    end
    key = if level isa AbstractString
        Symbol(uppercase(level))
    elseif level isa Integer
        Int(level)
    else
        level   # Symbol
    end   # Symbol
    if !haskey(_CUSTOM_LEVELS, key)
        ngc_warn("custom_log: level `", key, "` is not registered; skipping `", msg, "`")
        return nothing
    end
    _emit(_CUSTOM_LEVELS[key], msg)
end

# ── Initialization ────────────────────────────────────────────────────────────

"""
    init_logging(; logging_file=nothing, logging_level=Error, hide_console=false,
                  custom_levels::AbstractDict=Dict{Symbol,Int}())

Idempotent logger setup. Mirrors upstream `init_logging` (logger.py:72-105).
Installs any `custom_levels` first (so they're available to subsequent file/
console output), then constructs a logger that:

  - writes to `stderr` (unless `hide_console=true`)
  - tees to `logging_file` (mode `"a+"`) if given, prepended with the upstream
    `~~~~~/New Log <UTC timestamp>/~~~~~` banner

`logging_level` may be a `Logging.LogLevel`, an `Int`, or a `Symbol`/`String`
(uppercased and matched against the stdlib names: `Debug` / `Info` / `Warn` /
`Error` — and any name previously installed via `add_logging_level`).
"""
function init_logging(;
    logging_file::Union{Nothing, AbstractString}=nothing,
    logging_level=_DEFAULT_LOG_LEVEL,
    hide_console::Bool=_DEFAULT_HIDE_CONSOLE,
    custom_levels::AbstractDict=Dict{Symbol, Int}())
    # Phase 1: install custom levels.
    for (name, num) in custom_levels
        sym = name isa Symbol ? name : Symbol(name)
        haskey(_CUSTOM_LEVELS, sym) || add_logging_level(sym, Int(num))
    end

    # Phase 2: resolve string/symbol level → LogLevel.
    level = _resolve_level(logging_level)

    # Phase 3: build the routed logger.
    base = hide_console ? nothing : Logging.ConsoleLogger(stderr, level)

    file_logger = if logging_file !== nothing
        io = open(logging_file, "a+")
        banner = "~~~~~/New Log " * string(now(UTC)) * "/~~~~~"
        write(io, banner * "\n")
        flush(io)
        Logging.ConsoleLogger(io, level)
    else
        nothing
    end

    _NGC_LOGGER().logger = if base !== nothing && file_logger !== nothing
        _TeeLogger(base, file_logger)
    elseif base !== nothing
        base
    elseif file_logger !== nothing
        file_logger
    else
        Logging.NullLogger()
    end
    nothing
end

# Internal helper: resolve various level inputs to a Logging.LogLevel.
function _resolve_level(x)
    x isa Logging.LogLevel && return x
    x isa Integer && return Logging.LogLevel(Int(x))
    if x isa AbstractString || x isa Symbol
        sym = x isa Symbol ? x : Symbol(uppercase(String(x)))
        sym === :DEBUG && return Logging.Debug
        sym === :INFO && return Logging.Info
        sym === :WARN && return Logging.Warn
        sym === :ERROR && return Logging.Error
        haskey(_CUSTOM_LEVELS, sym) && return _CUSTOM_LEVELS[sym]
        ngc_error("unknown logging level `", sym, "`")
    end
    ngc_error("cannot resolve logging level from `", typeof(x), "`")
end

# Minimal two-sink TeeLogger — sends each record to both inner loggers.
# The AbstractLogger interface (per Logging stdlib docs):
#   shouldlog(logger, level, _module, group, id)            -> Bool   (5 args)
#   handle_message(logger, level, message, _module,
#                  group, id, file, line; kwargs...)         -> Nothing (8 args)
#   min_enabled_level(logger)                                -> LogLevel
#   catch_exceptions(logger)                                 -> Bool
struct _TeeLogger <: Logging.AbstractLogger
    a::Logging.AbstractLogger
    b::Logging.AbstractLogger
end
Logging.min_enabled_level(t::_TeeLogger) =
    min(Logging.min_enabled_level(t.a), Logging.min_enabled_level(t.b))
Logging.shouldlog(t::_TeeLogger, level, _module, group, id) =
    Logging.shouldlog(t.a, level, _module, group, id) ||
    Logging.shouldlog(t.b, level, _module, group, id)
Logging.catch_exceptions(::_TeeLogger) = false
function Logging.handle_message(t::_TeeLogger, level, message, _module,
    group, id, file, line; kwargs...)
    # Forward to BOTH inner loggers unconditionally — they each made their own
    # shouldlog decision before getting here (when dispatched via @logmsg →
    # current_logger() → our TeeLogger), but our top-level shouldlog returned
    # true if EITHER inner one wanted it. Re-checking here filters per-sink.
    if Logging.shouldlog(t.a, level, _module, group, id)
        Logging.handle_message(t.a, level, message, _module, group, id,
            file, line; kwargs...)
    end
    if Logging.shouldlog(t.b, level, _module, group, id)
        Logging.handle_message(t.b, level, message, _module, group, id,
            file, line; kwargs...)
    end
    nothing
end

# ── Exports (re-exported by NGCSimLib top-level) ──────────────────────────────

export ngc_warn, ngc_info, ngc_debug, ngc_error, ngc_critical,
    add_logging_level, custom_log, init_logging
