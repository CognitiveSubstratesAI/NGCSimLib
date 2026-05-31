# 06 — Support Modules (logger, configManager, deprecators, global_state, utils, public entry)

Phase A — Python → Julia 1:1 port. This spec covers the **misc / housekeeping**
pieces of `ngcsimlib`. They are individually small but contain the **public entry
point** (`ngcsimlib/__init__.py`) and three load-bearing globals (logger config,
config manager, global-state manager). If these mis-port, nothing downstream works.

---

## Purpose of this module group

Ten files, four roles:

1. **Public entry surface** — `ngcsimlib/__init__.py` and the per-subpackage public
   shims (`ngcsimlib/logger/__init__.py`, `…/global_state/__init__.py`, etc.). These
   define everything a user sees with `import ngcsimlib`. They are *re-exports* of
   names that live under `ngcsimlib/_src/`.
2. **Globals / process-wide state** — `_src/configManager.py`,
   `_src/global_state/manager.py`. Both are module-level singletons.
3. **Diagnostics / dev tools** — `_src/logger.py`, `_src/deprecators.py`,
   `_src/utils/help.py`, `_src/utils/priority.py`.
4. **Generic helpers** — `_src/utils/io.py` (paths + serializability check),
   `_src/utils/modules.py` (dynamic import / attribute discovery), `_src/utils/__init__.py`
   (empty, 0 bytes).

Files in scope:

| File | LoC | Role |
|---|---|---|
| `_src/__init__.py` | 76 (all comments) | dead/commented-out scratch — **NOT the entry point** |
| `ngcsimlib/__init__.py` | 46 | **REAL** entry point — `__version__`, `configure()`, re-exports |
| `_src/logger.py` | 205 | Module-level logger, dynamic levels, raise-on-error/critical |
| `_src/configManager.py` | 75 | Module-level JSON config singleton |
| `_src/deprecators.py` | 36 | `@deprecated`, `@deprecate_args` decorators |
| `_src/global_state/manager.py` | 106 | Singleton holding all compartment values |
| `_src/global_state/__init__.py` | 1 | re-export of `global_state_manager` |
| `_src/utils/__init__.py` | 0 bytes | **EMPTY — exports nothing** |
| `_src/utils/io.py` | 54 | Safe-filename, unique-path, serializability probe |
| `_src/utils/priority.py` | 7 | `@priority(value)` decorator |
| `_src/utils/modules.py` | 166 | Dynamic module / attribute loader (`_Loaded_Modules`, `_Loaded_Attributes`) |
| `_src/utils/help.py` | 111 | `Guides` builder for component introspection |

---

## ngcsimlib/`__init__.py` — PUBLIC ENTRY POINT

File: `/home/shivaji1012/JuliaAGI/dev-zone/ngc-sim-lib/ngcsimlib/__init__.py`

**NOTE**: This is the real entry point. `_src/__init__.py` is dead — every line in
it is a Python comment (lines 1–76). Do not port `_src/__init__.py`.

### Exports (top-level `ngcsimlib`)

From `ngcsimlib/__init__.py:1-6`:

```python
from ngcsimlib._src.component import Component as Component                  # :1
from ngcsimlib._src.process.methodProcess import MethodProcess               # :2
from ngcsimlib._src.process.jointProcess import JointProcess                 # :3
from ngcsimlib._src.deprecators import deprecated, deprecate_args            # :4
from ngcsimlib._src.configManager import init_config                         # :5
from ngcsimlib._src.configManager import get_config, provide_namespace       # :6
```

Plus the version constant `__version__` (line 17) read from
`importlib.metadata.version("ngcsimlib")` and the function `configure()` (lines
24–45).

### Public top-level surface (canonical list)

| Public name | Defined / re-exported from | Notes |
|---|---|---|
| `Component` | `_src/component.py` | Covered in spec 02 / 03 |
| `MethodProcess` | `_src/process/methodProcess.py` | spec 05 |
| `JointProcess` | `_src/process/jointProcess.py` | spec 05 |
| `deprecated` | `_src/deprecators.py:4` | this spec |
| `deprecate_args` | `_src/deprecators.py:14` | this spec |
| `init_config` | `_src/configManager.py:38` | this spec |
| `get_config` | `_src/configManager.py:49` | this spec |
| `provide_namespace` | `_src/configManager.py:63` | this spec |
| `__version__` | `ngcsimlib/__init__.py:17` | from package metadata |
| `configure` | `ngcsimlib/__init__.py:24` | CLI-arg parser for `--config <path>` |

### Per-subpackage public shims

These add **subpackage namespaces** that users may dot into (e.g.
`ngcsimlib.logger.warn(...)`):

* `ngcsimlib/logger/__init__.py:1-10` re-exports from `_src/logger.py`:
  `add_logging_level` (alias of `addLoggingLevel`), `init_logging`, `warn`,
  `error`, `critical`, `info`, `debug`, `custom_log`.
* `ngcsimlib/global_state/__init__.py:1` re-exports `global_state_manager`
  **renamed as `stateManager`**.
* `ngcsimlib/compartment/__init__.py:1-3` re-exports `Compartment`.
* `ngcsimlib/operations/__init__.py:1-5` re-exports `BaseOp`, `Summation`,
  `Product`.
* `ngcsimlib/parser/__init__.py:1-5` re-exports `compilable`, `parse_method`,
  `compileObject`.
* `ngcsimlib/context/__init__.py:2-9` re-exports `Context`, `ContextObjectTypes`,
  `global_context_manager` **renamed as `contextManager`**, `ContextAwareObject`,
  `component`, `process`.

### `configure()` semantics — `ngcsimlib/__init__.py:24-45`

```
parser = argparse.ArgumentParser(description='Build and run a model using ngclearn')
parser.add_argument("--config", type=str, help='location of config.json file')
args, unknown = parser.parse_known_args()           # :29 — TOLERATES other CLI args
try:    config_path = args.config                   # :31
except: config_path = None                          # :33
if config_path is None: config_path = "json_files/config.json"   # :36
if not os.path.isfile(config_path): return          # :38 — silent fallback
init_config(config_path)                            # :45
```

Behaviour:
1. Adds `--config <path>` to argparse, but ignores all other args (`parse_known_args`).
2. Defaults to `"json_files/config.json"` relative to `pwd`.
3. If file does not exist, **returns silently** (no exception). Logger comments at
   lines 39–43 are commented-out by upstream — intentionally quiet.
4. Otherwise, calls `init_config(path)` which loads JSON into the config singleton.

### Julia equivalent

```julia
module NGCSimLib
  export Component, MethodProcess, JointProcess,
         deprecated, deprecate_args, init_config, get_config, provide_namespace,
         configure
  const VERSION = pkgversion(@__MODULE__)   # replaces __version__
  # submodules for namespaced access: NGCSimLib.Logger, NGCSimLib.GlobalState, etc.
  include("logger.jl");      using .Logger
  include("globalstate.jl"); using .GlobalState
  ...
end
```

For `configure()`, port to a Julia function that uses `ArgParse.jl` (or hand-rolls
`ARGS` parsing — the surface is one flag) and tolerates extra args.

---

## logger.py — `_src/logger.py`

File: `/home/shivaji1012/JuliaAGI/dev-zone/ngc-sim-lib/ngcsimlib/_src/logger.py`

Wraps Python's stdlib `logging` with the ngcsimlib-flavoured conventions:
print-style varargs, raise-on-error, raise-on-critical, runtime-extensible custom
log levels.

### Module-level state

* `_ngclogger = logging.getLogger("ngclogger")` — line 17. Single named logger
  shared by all callers.
* `_mapped_calls: dict[int|str, Callable] = {}` — line 19. Lookup table that maps
  a custom level *number* AND *name* to the bound method on `_ngclogger`. Populated
  by `addLoggingLevel`. Used only by `custom_log`.

### Inventory

| Name | Lines | Kind | Purpose |
|---|---|---|---|
| `_concatArgs(func)` | 7–14 | private decorator | Joins `*wargs` with `sep=" "` then `+ end`. Mimics Python `print` signature. Wraps every public log function. |
| `addLoggingLevel(levelName, levelNum, methodName=None)` | 22–69 | public | Installs a **new logging level** on the `logging` stdlib module AND the `Logger` class (per stackoverflow recipe, credited in docstring line 33). Sets `logging.<LEVELNAME> = levelNum`, monkey-patches `logForLevel` / `logToRoot`, then registers entries in `_mapped_calls` keyed by both `levelNum` and `levelName`. Raises `AttributeError` if name collides (lines 47, 50, 53). |
| `init_logging()` | 72–105 | public | Idempotent setup. Reads `logging` config section. Installs `custom_levels` first. Coerces a string `logging_level` to a numeric one via `logging.getLevelName(...)` (lines 84–86). Sets `_ngclogger` level. Adds a `StreamHandler(sys.stderr)` unless `hide_console=True` (lines 92–95). Adds a `FileHandler` if `logging_file` is set, prepending a `~~~~~/New Log <UTC timestamp>/~~~~~` banner to the file (lines 97–105). |
| `warn(msg)` | 108–118 | public | `_ngclogger.warning(msg)` — does NOT raise |
| `error(msg, errorCls=RuntimeError)` | 121–133 | public | logs then **raises** `errorCls(msg)` |
| `critical(msg)` | 136–147 | public | logs then **raises** `RuntimeError(msg)` (errorCls **not** configurable here) |
| `info(msg)` | 150–160 | public | `_ngclogger.info(msg)` |
| `debug(msg)` | 163–173 | public | `_ngclogger.debug(msg)` |
| `custom_log(msg, logging_level=None)` | 176–204 | public | Looks up `logging_level` (string upper-cased at :197, or numeric) in `_mapped_calls`. Warns if `None` (:200), warns if key not registered (:202), otherwise dispatches. |

### Defaults — `init_logging()` lines 73–77

```
logging_file:  None         # no file output
logging_level: logging.ERROR
hide_console:  False
```

### Config schema consumed (read from `get_config("logging")`)

```
{
  "logging_file":  Optional[str],          # path; opened with "a+"
  "logging_level": int | str,              # one of CRITICAL/ERROR/WARNING/INFO/DEBUG or custom
  "hide_console":  bool,                   # suppress stderr handler
  "custom_levels": Optional[dict[str, int]] # name -> numeric level
}
```

### Critical semantic notes

1. **`error()` and `critical()` are control flow, not just logging.** They raise.
   Callers expect them to abort. The Julia port must preserve this — do NOT replace
   with `@error` macro (which is fire-and-forget in Julia).
2. **`warn`/`error`/etc are decorated with `_concatArgs`**. Callers pass varargs:
   `warn("kwarg", kwarg, "is deprecated")` — see `_src/deprecators.py:6`. The
   decorator joins with `" "`. Julia port must preserve varargs concat.
3. **`_mapped_calls` is shared mutable state.** Custom levels survive across calls.

### Julia equivalent

Use Julia's `Logging` stdlib **as the sink** but write thin wrapper functions that
preserve the raise-on-error semantic.

```julia
module Logger
  using Logging, Dates

  const _CUSTOM_LEVELS = Dict{Union{Symbol,Int},LogLevel}()
  const _LOGGER = Ref{AbstractLogger}(ConsoleLogger(stderr, Logging.Error))

  _concat(args...; sep=" ", finish="") = join((string(a) for a in args), sep) * finish

  warn(args...; kwargs...)  = (@logmsg Logging.Warn _concat(args...; kwargs...); nothing)
  info(args...; kwargs...)  = (@logmsg Logging.Info _concat(args...; kwargs...); nothing)
  debug(args...; kwargs...) = (@logmsg Logging.Debug _concat(args...; kwargs...); nothing)

  function error(args...; errortype=ErrorException, kwargs...)
      msg = _concat(args...; kwargs...)
      @logmsg Logging.Error msg
      throw(errortype(msg))   # MATCH Python: raise
  end

  function critical(args...; kwargs...)
      msg = _concat(args...; kwargs...)
      @logmsg LogLevel(2000) msg   # above Error
      throw(ErrorException(msg))   # ALWAYS raises ErrorException, no override (matches :147)
  end

  add_logging_level(name::Symbol, num::Int) = (_CUSTOM_LEVELS[name] = LogLevel(num);
                                               _CUSTOM_LEVELS[num]  = LogLevel(num); nothing)
end
```

Note: `_ngclogger` is a named logger; Julia uses `LoggingExtras.jl` for routed
handlers. For phase A keep a global `Ref{AbstractLogger}` and install handlers in
`init_logging()`.

---

## configManager.py — `_src/configManager.py`

File: `/home/shivaji1012/JuliaAGI/dev-zone/ngc-sim-lib/ngcsimlib/_src/configManager.py`

A trivial **JSON-file-backed config singleton**.

### State

* `_GlobalConfig = _ConfigManager()` — line 35. Module-level singleton.
* `_ConfigManager.loadedConfig: Optional[dict]` — line 12. `None` until `init_config`
  is called.

### Class — `_ConfigManager` (lines 10–32)

| Method | Lines | Behaviour |
|---|---|---|
| `__init__` | 11–12 | sets `loadedConfig = None` |
| `init_config(path)` | 14–16 | `open(path)` → `json.load` → store in `loadedConfig` |
| `get_config(name)` | 18–25 | Returns `loadedConfig[name]` or `None` if unset / missing. Two guards: `loadedConfig is None` (:19) and `name not in keys()` (:22). |
| `provide_namespace(configName)` | 27–32 | Calls `get_config(configName)`, wraps in `types.SimpleNamespace(**config)` so users can dot-access fields. Returns `None` if section absent. |

### Module-level wrappers (lines 38–74)

* `init_config(path)` → delegates to `_GlobalConfig.init_config(path)`
* `get_config(configName)` → delegates to `_GlobalConfig.get_config(configName)`
* `provide_namespace(configName)` → delegates

### Config schema (no validation)

There is **no schema** and **no validation**. Whatever JSON is loaded is stored
verbatim. Consumers (logger.py line 73; the commented-out `preload_modules` in
`_src/__init__.py`) request top-level keys by name. Known consumers:

| Consumer | Key requested | Schema (implicit) |
|---|---|---|
| `logger.init_logging` | `"logging"` | `{logging_file, logging_level, hide_console, custom_levels}` |
| (dead) `preload_modules` | `"modules"` | `{module_path: str}` |

### Julia equivalent

Use `JSON3.jl` for the load. `SimpleNamespace` becomes `NamedTuple` (immutable,
dot-access). Schema-less, just like Python.

```julia
module ConfigMgr
  using JSON3
  const _LOADED = Ref{Union{Nothing,Dict{String,Any}}}(nothing)

  init_config(path::AbstractString) = (_LOADED[] = Dict(JSON3.read(read(path,String))); nothing)

  function get_config(name::AbstractString)
      _LOADED[] === nothing && return nothing
      return get(_LOADED[], name, nothing)
  end

  function provide_namespace(name::AbstractString)
      cfg = get_config(name); cfg === nothing && return nothing
      return NamedTuple{Tuple(Symbol.(keys(cfg)))}(values(cfg))
  end
end
```

**Do NOT** swap to TOML.jl — upstream uses JSON. Keep on-disk format identical to
preserve cross-language artifact compatibility.

---

## deprecators.py — `_src/deprecators.py`

File: `/home/shivaji1012/JuliaAGI/dev-zone/ngc-sim-lib/ngcsimlib/_src/deprecators.py`

Two decorators. Both attach the **sentinel attributes** `_is_deprecated = True`
and `_original = fn` to the wrapper so callers can introspect.

### `@deprecated` — lines 4–11

```python
def deprecated(fn):
    def _wrapped(*args, **kwargs):
        warn(fn.__qualname__, "is deprecated")    # :6 — emits warning every call
        return fn(*args, **kwargs)
    _wrapped._is_deprecated = True                 # :9
    _wrapped._original = fn                        # :10
    return _wrapped
```

Behaviour: every call emits a `warn` and proceeds.

### `@deprecate_args(_rebind=True, **arg_list)` — lines 14–35

Per-kwarg deprecation. `arg_list` maps `old_kw -> new_kw_or_None`.

```python
def deprecate_args(_rebind=True, **arg_list):
    def _deprecate_args(fn):
        def _wrapped(*args, **kwargs):
            for kwarg in list(kwargs.keys()):
                if kwarg in arg_list.keys():
                    new_kwarg = arg_list[kwarg]
                    if new_kwarg is None:
                        warn(f"The argument \"{kwarg}\" is deprecated for {fn.__qualname__}, "
                             f"and will no longer be supported")               # :21
                    else:
                        warn(f"The argument \"{kwarg}\" is deprecated for {fn.__qualname__}, "
                             f"use \"{new_kwarg}\" instead")                   # :23
                    if _rebind:                                                # :25
                        if new_kwarg is not None:
                            kwargs[new_kwarg] = kwargs[kwarg]                  # :27
                        del kwargs[kwarg]                                      # :28
            return fn(*args, **kwargs)
        _wrapped._is_deprecated = True                                          # :32
        _wrapped._original = fn                                                 # :33
        return _wrapped
    return _deprecate_args
```

Semantics:
* If `new_kwarg is None` → kwarg is being removed entirely (warn + drop).
* If `new_kwarg` is a string → kwarg is being renamed (warn + copy value under new
  name + drop old).
* If `_rebind=False` → keep the old kwarg untouched (only warn).

### Used by

`_src/context/contextAwareObjectMeta.py:11` does
`if getattr(init, "_is_deprecated", False):` to enforce that a class isn't using
a deprecated `__init__`. So **the sentinel `_is_deprecated` must be visible to
introspection** — this is not just cosmetic.

### Julia equivalent

Julia has `Base.@deprecate` but it works at **module-level binding time**, not on
arbitrary callables, and it does not attach sentinels. Roll our own:

```julia
const _DEPRECATED_REGISTRY = IdDict{Function,Function}()   # wrapper -> original

is_deprecated(fn) = haskey(_DEPRECATED_REGISTRY, fn)
original_of(fn)   = get(_DEPRECATED_REGISTRY, fn, fn)

macro deprecated(fnexpr)
    quote
        local _orig = $(esc(fnexpr))
        local _wrapped = (args...; kwargs...) -> begin
            Logger.warn(string(nameof(_orig)), " is deprecated")
            return _orig(args...; kwargs...)
        end
        _DEPRECATED_REGISTRY[_wrapped] = _orig
        _wrapped
    end
end
```

For `deprecate_args`, the parameter-name renaming is straightforward in Julia
because kwargs are a `NamedTuple` / `Iterators.Pairs` — iterate and rebuild.

**Do NOT use `Base.@deprecate`** — it's wrong shape (replaces bindings rather than
wrapping callables).

---

## global_state/manager.py — `_src/global_state/manager.py`

File: `/home/shivaji1012/JuliaAGI/dev-zone/ngc-sim-lib/ngcsimlib/_src/global_state/manager.py`

**This is one of the three load-bearing globals.** It holds the entire runtime
state of every compartment in the system, keyed by a composite path.

### State

* `global_state_manager = __global_state_manager()` — line 105. Module-level
  singleton.
* Two private dicts inside the singleton:
  * `self.__state: Dict[str, Any]` — line 9. Maps `"<path>:<local_key>"` → value
    (parameter array, compartment value, etc.).
  * `self.__compartments: Dict[str, Compartment]` — line 10. Maps `root` (the
    composite name a compartment was registered under) → the `Compartment` object
    itself. Used so a `Process` can look up a compartment by name.

### Key format

Line 28: `return path + ":" + local_key`. A literal `path:local_key` string. So
`"net.layer1.W:value"` (made by `make_key("net.layer1.W", "value")`).

### Methods

| Method | Lines | Behaviour |
|---|---|---|
| `add_compartment(c)` | 12–13 | `self.__compartments[c.root] = c` |
| `get_compartment(root)` | 15–16 | direct dict lookup; **throws KeyError** if missing (no `.get` with default — by design) |
| `make_key(path, local_key)` *static* | 18–28 | `f"{path}:{local_key}"` |
| `check_key(global_key)` | 30–39 | `global_key in self.__state.keys()` |
| `add_key(path, local_key, value)` | 41–52 | `self.__state[make_key(path, local_key)] = value` |
| `from_global_key(key)` | 54–63 | `self.__state.get(key, None)` — soft lookup |
| `from_local_key(path, local_key)` | 65–77 | combines `make_key` + `from_global_key` |
| `set_state(state: Dict)` | 79–86 | `self.__state.update(state)` — partial overwrite, NOT replace |
| `state` *property* | 88–93 | returns **a copy** (`self.__state.copy()`). Defensive. |
| `state.setter` | 95–102 | delegates to `set_state` — so `gsm.state = {...}` does an `update`, not a replace |

### Critical semantic notes

1. **Singleton via module-level binding.** Line 105 creates the instance. Any
   `from ngcsimlib._src.global_state.manager import global_state_manager`
   gets the same object. **Not** task-local. **Not** thread-local.
2. **Not thread-safe.** No locks. Python relies on the GIL; in Julia we lose this
   guarantee. See "Open questions" below.
3. **`set_state` does `update`, not `=`.** Partial state from a JIT-compiled
   process body is merged back (`_src/process/baseProcess.py:139`).
4. **Returned `state` is a defensive copy.** Mutating it does NOT mutate the
   singleton. Julia port must preserve this — return `copy(_state)`, not the dict
   itself.

### Used by (consumers — grep'd)

* `_src/operations/BaseOp.py:3`
* `_src/process/baseProcess.py:3,134,139`
* `_src/process/methodProcess.py:2,107`
* `_src/process/jointProcess.py:6,80`
* `_src/context/context.py:9,350`
* `_src/parser/contextTransformer.py:5,63`
* `_src/compartment/compartment.py:2`

This is **the** central data plane. Touch carefully.

### Julia equivalent

```julia
module GlobalState
  using ..Compartments: Compartment        # forward decl; circular dep handled via abstract type

  mutable struct GlobalStateManager
      state::Dict{String,Any}
      compartments::Dict{String,Compartment}
      lock::ReentrantLock                  # NEW vs Python — see hazards
  end
  GlobalStateManager() = GlobalStateManager(Dict{String,Any}(), Dict{String,Compartment}(), ReentrantLock())

  const GLOBAL_STATE_MANAGER = GlobalStateManager()

  make_key(path, local_key) = string(path, ':', local_key)

  add_compartment!(c) = (lock(GLOBAL_STATE_MANAGER.lock) do
      GLOBAL_STATE_MANAGER.compartments[c.root] = c
  end; nothing)

  get_compartment(root) = GLOBAL_STATE_MANAGER.compartments[root]  # throws KeyError, matches :16

  check_key(global_key) = haskey(GLOBAL_STATE_MANAGER.state, global_key)

  add_key!(path, local_key, value) = (GLOBAL_STATE_MANAGER.state[make_key(path,local_key)] = value; nothing)
  from_global_key(key)             = get(GLOBAL_STATE_MANAGER.state, key, nothing)
  from_local_key(path, local_key)  = from_global_key(make_key(path, local_key))

  set_state!(state::AbstractDict)  = merge!(GLOBAL_STATE_MANAGER.state, state)
  get_state()                      = copy(GLOBAL_STATE_MANAGER.state)   # DEFENSIVE COPY
end
```

**Why not task-local?** Python's singleton is process-wide. Reactant.jl traces
typically run on a single thread; the parallel story is via XLA, not Julia
threads. Matching the upstream model = module-level `const` with an internal
`ReentrantLock` for hygiene.

---

## utils/`__init__.py` — `_src/utils/__init__.py`

File: `/home/shivaji1012/JuliaAGI/dev-zone/ngc-sim-lib/ngcsimlib/_src/utils/__init__.py`

**0 bytes. EMPTY.** Read tool reported "The file has 1 lines" (likely 1 empty
line / 0-byte file).

**Implication**: `from ngcsimlib._src.utils import io, modules, ...` works only by
explicit submodule import — there is no `__all__` and no auto-export. Each util
file is imported by its consumers directly (`from ngcsimlib._src.utils.io import
make_unique_path` — `_src/context/context.py:5`).

### Julia equivalent

There is no `utils/__init__.py` to port. In Julia, the `Utils` submodule should
likewise NOT auto-include or re-export — let callers `using NGCSimLib.Utils.IO:
make_unique_path` etc. Or simpler: collapse all utils into a single `utils.jl`
file (see "Julia translation notes" below).

---

## utils/io.py — `_src/utils/io.py`

File: `/home/shivaji1012/JuliaAGI/dev-zone/ngc-sim-lib/ngcsimlib/_src/utils/io.py`

### Inventory

| Name | Lines | Behaviour |
|---|---|---|
| `make_safe_filename(name, replacement='_')` | 3–5 | Replaces spaces with `_`. Regex `r'[ <>:"/\\|?*\0-\31]'` replaces invalid filename chars (control chars 0–31, plus `<>:"/\|?*`). Strips trailing whitespace via `.strip()`. |
| `make_unique_path(directory, root_name=None)` | 7–34 | Generates a unique directory under `directory`. If `root_name=None` → uses `uuid.uuid4()` as the name. If `directory/root_name` already exists → appends `_<uuid>`. Then `os.mkdir(path)` and returns the path. **Prints** (not logs) the generated name (lines 25, 29). |
| `check_serializable(dict)` | 37–53 | Returns a list of keys whose values raise on `json.dumps`. Used to detect non-JSON-serializable params before save. |

### Used by

* `_src/context/context.py:5` imports both `make_unique_path` and
  `make_safe_filename`. Used to build per-model save directories
  (`_src/context/context.py:247,261,270,324`).
* `check_serializable` — no internal callers grep'd. Probably available for user
  code / future serialization layer.

### Julia equivalent

```julia
function make_safe_filename(name::AbstractString; replacement::AbstractString="_")
    s = replace(name, ' ' => replacement)
    # Regex equivalent of r'[ <>:"/\\|?*\0-\31]'
    return strip(replace(s, r"[ <>:\"/\\|?*\x00-\x1F]" => replacement))
end

function make_unique_path(directory::AbstractString, root_name::Union{Nothing,AbstractString}=nothing)
    uid = string(UUIDs.uuid4())
    if root_name === nothing
        root_name = uid
        println("generated path will be named \"$root_name\"")
    elseif isdir(joinpath(directory, root_name))
        root_name = string(root_name, "_", uid)
        println("root path already exists, generated path will be named \"$root_name\"")
    end
    path = joinpath(directory, root_name)
    mkdir(path)
    return path
end

function check_serializable(d::AbstractDict)
    bad = String[]
    for (k, v) in d
        try; JSON3.write(v); catch; push!(bad, string(k)); end
    end
    return bad
end
```

Stdlib deps: `UUIDs`, `JSON3`. No HDF5 — upstream does not use it.

---

## utils/priority.py — `_src/utils/priority.py`

File: `/home/shivaji1012/JuliaAGI/dev-zone/ngc-sim-lib/ngcsimlib/_src/utils/priority.py`

118 bytes, 7 lines. It's NOT an enum — it's a **decorator factory** that attaches
`_priority = value` to the wrapped function.

```python
def priority(value=None):
    def decorator(fn):
        fn._priority = value
        return fn
    return decorator
```

### Consumers (grep'd)

* `_src/process/baseProcess.py:5` imports it.
* `_src/process/jointProcess.py:17-18` reads `process._priority` to order joint
  processes:

  ```python
  if process._priority <= self._priority:
      self._priority = process._priority - 1
  ```

* `_src/context/context.py:85,93,334` reads `getattr(obj, "_priority", None) or 0`
  as a sort key when iterating context objects.

### Critical semantic note

Decorator does NOT wrap the function — it **mutates the existing function in
place** and returns it. So `@priority(5)` on a function makes
`fn._priority == 5` directly; there is no wrapper closure to peel off.

### Julia equivalent

Julia functions cannot have arbitrary attributes attached. Two options:

**Option A — separate registry (recommended for 1:1 port fidelity):**

```julia
const _PRIORITY_REGISTRY = IdDict{Any,Int}()
priority(fn, value::Int) = (_PRIORITY_REGISTRY[fn] = value; fn)
get_priority(fn) = get(_PRIORITY_REGISTRY, fn, 0)
```

**Option B — types-as-callables, with `priority` as a field on the struct.** This
fits the spec-02 model where components are structs, but doesn't fit free
functions.

For 1:1 port: Option A. Anywhere upstream reads `obj._priority`, port code calls
`get_priority(obj)`.

---

## utils/modules.py — `_src/utils/modules.py`

File: `/home/shivaji1012/JuliaAGI/dev-zone/ngc-sim-lib/ngcsimlib/_src/utils/modules.py`

Dynamic module / attribute discovery. Lets the user reference classes by string
name and have them resolved at runtime from any already-imported module. Used for
the (commented-out) JSON-driven model construction pattern.

### State

* `_Loaded_Modules: Dict[str, ModuleType]` — line 8. Cache of resolved modules.
* `_Loaded_Attributes: Dict[str, Any]` — line 7. Cache of resolved attributes
  (classes, functions).

Both are **module-level mutable globals**, just like the other singletons in this
group.

### Inventory

| Name | Lines | Behaviour |
|---|---|---|
| `check_attributes(obj, required, fatal=False)` | 10–40 | For each name in `required`, checks `hasattr(obj, name)`. If `fatal=True`, raises `AttributeError` with `obj.name` if available, else generic message. Returns `True`/`False` if non-fatal. `required is None` → returns `True`. |
| `load_module(module_path, match_case=False, absolute_path=False)` | 43–87 | Caches first (`_Loaded_Modules`). If `absolute_path=True` → `import_module(module_path)` directly. Else → scan `sys.modules`, match by **last dotted component** (case-insensitive by default — line 70), and `import_module` the matched name. Raises `RuntimeError` if no match. |
| `load_from_path(path, match_case=False, absolute_path=False)` | 90–117 | If `absolute_path=True`, splits the path into `module_name` (everything before last `.`) and `class_name` (last segment), forces `match_case=True`. Otherwise both `module_name` and `class_name` equal the input path. Delegates to `load_attribute`. |
| `load_attribute(attribute_name, module_path=None, match_case=False, absolute_path=False)` | 120–165 | Cache lookup (`_Loaded_Attributes`). Calls `load_module`. If `match_case=False` → **capitalises first letter** of `attribute_name` (lines 149–152), so `load_attribute("component")` looks up `mod.Component`. `getattr` and raise `RuntimeError` on `AttributeError` (lines 154–162). |

### Critical semantic notes

1. **Case-insensitive class lookup by default.** Line 149-152: if not
   `match_case`, `attribute_name[0].upper() + attribute_name[1:]`. So
   `load_attribute("rateCell")` looks up `mod.RateCell`. **This is a 1:1
   conformance requirement** if you want any user-facing string-key model
   construction to work.
2. **Last-component module matching** (lines 68–78). `load_module("commands")`
   searches `sys.modules` for any module whose last dot-component is
   `"commands"`. This means user-provided extension modules are auto-discovered
   once imported anywhere.
3. **No consumers in current `_src` tree** — `grep` finds zero internal callers
   of `load_module`/`load_attribute`/`load_from_path`. The commented-out
   `preload_modules` in `_src/__init__.py:39-51` was the original consumer; it
   used these to populate `_Loaded_Modules`/`_Loaded_Attributes` from a JSON
   manifest. Reachable only via user code today.

### Julia equivalent

Direct port is **possible but unidiomatic**. Julia's reflection works through
`Module`, `getfield`, and `Base.loaded_modules`.

```julia
const _LOADED_MODULES    = Dict{String,Module}()
const _LOADED_ATTRIBUTES = Dict{String,Any}()

function load_module(module_path::AbstractString; match_case::Bool=false, absolute_path::Bool=false)
    haskey(_LOADED_MODULES, module_path) && return _LOADED_MODULES[module_path]
    if absolute_path
        mod = Base.require(Base.identify_package(module_path))
    else
        final = split(module_path, '.')[end]
        final_norm = match_case ? final : lowercase(final)
        mod = nothing
        for m in values(Base.loaded_modules)
            last = string(nameof(m))
            last_norm = match_case ? last : lowercase(last)
            if final_norm == last_norm
                Logger.info("Loading module from ", string(m))
                mod = m
                break
            end
        end
        mod === nothing && throw(ErrorException("Failed to find dynamic import for \"$module_path\""))
    end
    _LOADED_MODULES[module_path] = mod
    return mod
end

function load_attribute(attribute_name::AbstractString; module_path=nothing, match_case=false, absolute_path=false)
    haskey(_LOADED_ATTRIBUTES, attribute_name) && return _LOADED_ATTRIBUTES[attribute_name]
    mod = load_module(module_path === nothing ? attribute_name : module_path;
                      match_case=match_case, absolute_path=absolute_path)
    name = match_case ? attribute_name : uppercase(attribute_name[1:1])*attribute_name[2:end]
    attr = try; getfield(mod, Symbol(name)); catch; throw(ErrorException("Could not find attribute \"$name\" in module $(nameof(mod))")); end
    _LOADED_ATTRIBUTES[attribute_name] = attr
    return attr
end
```

`check_attributes` is trivially `hasproperty(obj, name)` in Julia.

---

## utils/help.py — `_src/utils/help.py`

File: `/home/shivaji1012/JuliaAGI/dev-zone/ngc-sim-lib/ngcsimlib/_src/utils/help.py`

Builds **string documentation guides** for component classes. The class under
help is expected to implement a `help()` classmethod returning a nested dict;
this module formats it.

### Inventory

| Name | Lines | Kind |
|---|---|---|
| `_HelpSection(section_path, section_title, blank_msg, indent=1)` | 4–29 | private class. `write(data)` descends `data` along `/`-separated `section_path`, then renders `key: value` lines. If `data is None` and `blank_msg == ""` → returns empty string. |
| `_BlockSection(*lines, indent=1)` | 32–42 | private class. Static block of indented text. `write(kls)` ignores its arg, just emits `self.lines`. |
| `_input_section` | 45–47 | singleton — `_HelpSection("compartments/inputs", "Input Compartments", "There are no required inputs")` |
| `_output_section` | 49–51 | singleton — `_HelpSection("compartments/outputs", "Output Compartments", "There are no expected outputs")` |
| `_param_section` | 53–55 | singleton — `_HelpSection("hyperparameters", "Hyperparameters", "There are no required hyperparameters")` |
| `GuideList(Enum)` | 58–64 | enum of guide identifiers: `Input="input"`, `Output="output"`, `Parameters="params"`, `Monitoring="monitoring"`, `Wiring="wiring"`. |
| `Guides(base_cls)` | 67–110 | builder. On `__init__`, calls `base_cls.help()`, then writes 5 attribute strings: `self.inputs`, `self.outputs`, `self.monitoring`, `self.params`, `self.wiring`. |

### Static guide definitions in `Guides`

Lines 84–90 (these are **private class-level tuples**):

```python
__inputs     = "Input Guide",     [_input_section]
__outputs    = "Output Guide",    [_output_section]
__params     = "Parameter Guide", [_param_section]
__monitoring = "Monitoring Guide", [_output_section],   # NB: trailing comma → tuple of 1
__wiring     = "Wiring Guide",    [_input_section, _output_section]
```

**Note**: line 89 has a trailing comma. `__monitoring` is therefore a tuple of one
element `(("Monitoring Guide", [_output_section]),)` rather than the
2-tuple `("Monitoring Guide", [_output_section])`. This is **almost certainly a
bug** — line 98 then does `self.__write_guide(*self.__monitoring)` which would
unpack a 1-tuple into a single arg, leaving `sections` unbound. Flag in "Open
questions / hazards".

### Used by

`grep` finds zero `Guides(...)` or `GuideList.` consumers in `_src/`. This module
is intended for end-user introspection — e.g. an IDE plugin or REPL command. No
internal runtime path depends on it.

### Julia equivalent

`?MyComponent` in Julia already gives docstrings; we should generate these strings
from a method that the component itself provides, e.g.:

```julia
abstract type AbstractComponent end
help(::Type{<:AbstractComponent}) = Dict()   # override per component

function guides(T::Type{<:AbstractComponent})
    h = help(T)
    return (
        inputs     = _write_section(h, "compartments/inputs",  "Input Compartments",     "There are no required inputs"),
        outputs    = _write_section(h, "compartments/outputs", "Output Compartments",    "There are no expected outputs"),
        params     = _write_section(h, "hyperparameters",      "Hyperparameters",        "There are no required hyperparameters"),
        monitoring = _write_section(h, "compartments/outputs", "Output Compartments",    "There are no expected outputs"),
        wiring     = _write_section_multi(h, [
                       ("compartments/inputs",  "Input Compartments",  "There are no required inputs"),
                       ("compartments/outputs", "Output Compartments", "There are no expected outputs"),
                     ]),
    )
end
```

Low priority — this is end-user diagnostics, not runtime.

---

## Cross-module overlaps to flag

Who depends on this support group (grep results):

| Support module | Consumers |
|---|---|
| `_src/logger.py` (`warn`/`error`/`info`/etc.) | `_src/deprecators.py:1`; `_src/utils/modules.py:3`; `_src/context/context_manager.py:1`; `_src/context/context.py:4` (via shim); `_src/context/contextAwareObject.py:7`; `_src/context/contextAwareObjectMeta.py:3`; `_src/compartment/compartment.py:3`; `_src/process/baseProcess.py:4`; `_src/parser/contextTransformer.py:6` |
| `_src/configManager.py` (`get_config`) | `_src/logger.py:1`; commented-out in `_src/__init__.py`; re-exported by `ngcsimlib/__init__.py:5-6` |
| `_src/deprecators.py` (`deprecated`/`deprecate_args`) | re-exported by `ngcsimlib/__init__.py:4`; sentinel `_is_deprecated` checked in `_src/context/contextAwareObjectMeta.py:11` |
| `_src/global_state/manager.py` (`global_state_manager`) | `_src/operations/BaseOp.py:3`; `_src/compartment/compartment.py:2`; `_src/process/baseProcess.py:3`; `_src/process/methodProcess.py:2`; `_src/process/jointProcess.py:6`; `_src/context/context.py:9`; `_src/parser/contextTransformer.py:5` — **broadest reach in the codebase** |
| `_src/utils/io.py` (`make_unique_path`, `make_safe_filename`) | `_src/context/context.py:5,247,261,270,324` |
| `_src/utils/priority.py` (`priority`) | `_src/process/baseProcess.py:5`; read by `_src/process/jointProcess.py:17-18`; `_src/context/context.py:85,93,334` |
| `_src/utils/modules.py` (`load_*`, `_Loaded_*`) | none internal; user-facing only |
| `_src/utils/help.py` (`Guides`, `GuideList`) | none internal; user-facing only |

**Most load-bearing**: `global_state/manager.py`, then `logger.py`, then
`priority.py`.

---

## Julia translation notes

### Suggested module layout for NGCSimLib

```
NGCSimLib/
  src/
    NGCSimLib.jl            # top-level module, exports public API
    Logger.jl               # _src/logger.py     -> submodule NGCSimLib.Logger
    ConfigMgr.jl            # _src/configManager.py
    Deprecators.jl          # _src/deprecators.py
    GlobalState.jl          # _src/global_state/manager.py
    Utils/
      IO.jl                 # _src/utils/io.py
      Priority.jl           # _src/utils/priority.py
      Modules.jl            # _src/utils/modules.py
      Help.jl               # _src/utils/help.py
```

**Reasoning**:
* Keep submodules **separate** to mirror upstream namespaces (preserves the
  `NGCSimLib.Logger.warn(...)` user surface from `ngcsimlib.logger.warn(...)`).
* Do NOT collapse all utils into one `Utils.jl` — the Python module split is
  load-bearing for tooling (e.g. priority is a decorator factory; help is a
  doc builder; modules is a dynamic loader — three distinct mental models).
* Use `include` + `using` in `NGCSimLib` to wire it together.

### Python stdlib → Julia stdlib / registered packages

| Python | Julia |
|---|---|
| `logging` | `Logging` stdlib (sinks) + thin wrappers in `Logger.jl` for raise-on-error semantic |
| `json` | `JSON3.jl` |
| `argparse` (in `configure()`) | `ArgParse.jl` registered, or hand-roll for one flag |
| `importlib.metadata.version` | `pkgversion(@__MODULE__)` from `Pkg` (stdlib) |
| `types.SimpleNamespace` | `NamedTuple` |
| `uuid.uuid4` | `UUIDs.uuid4` (stdlib) |
| `os.mkdir`, `os.path.isfile`, `os.path.isdir` | `mkdir`, `isfile`, `isdir` (Base) |
| `re.sub` | `replace(s, r"..." => ...)` (Base) |
| `datetime.utcnow` | `Dates.now(UTC)` (Dates stdlib) |
| `importlib.import_module`, `sys.modules` | `Base.require` / `Base.loaded_modules` |
| `getattr(obj, name)` | `getfield(obj, Symbol(name))` or `getproperty` |
| `hasattr(obj, name)` | `hasproperty(obj, name)` |
| decorator attaching `_priority`/`_is_deprecated` | external `IdDict` registry |
| `enum.Enum` | `@enum` macro (Base) — or `Symbol` constants for string-valued enums |

### Phase-A non-goals

* HDF5, pickle, h5py — **not used** by upstream support modules; do not pull in
  `HDF5.jl`.
* TOML — **not used**; keep JSON for config compatibility.
* Logging routers / multi-sink frameworks — defer until `init_logging()` needs
  more than stderr + file handler. `LoggingExtras.jl` is the right Phase-B choice
  if needed.

---

## Open questions / hazards

1. **Thread safety of `global_state_manager`.** Python relies on the GIL.
   Julia does not have one. If Reactant traces run multi-threaded, concurrent
   `add_key!` / `get_state()` will race. **Recommendation**: add a
   `ReentrantLock` to the manager. Document that user code targeting Julia
   threads must hold the lock when batching mutations. Upstream behaviour
   (no locks) is the bug, not the contract.

2. **`Guides.__monitoring` trailing-comma bug** (`_src/utils/help.py:89`). The
   trailing comma makes `__monitoring` a 1-tuple, which line 98 unpacks
   incorrectly. Port should drop the trailing comma. Verify with upstream maintainer
   before "fixing" — it might be a never-triggered code path that throws on
   first use; safer to **port the bug 1:1 AND flag**, then patch in Phase B.

3. **`load_attribute` first-char-uppercase rule** (`_src/utils/modules.py:149-152`).
   Looks dangerous: `load_attribute("aBcDef")` becomes `"ABcDef"`, not `"Abcdef"`.
   It does NOT lowercase the rest. This may be an intentional convention to support
   `camelCase` -> `CamelCase` class names. **Port verbatim**.

4. **No exposed test for `init_logging` idempotency.** Calling it twice would add
   two stream handlers and produce duplicate log lines (line 95 unconditionally
   `addHandler`). Upstream doesn't guard against this — neither should the port,
   but flag for Phase-B hardening.

5. **`error()` vs `critical()` semantic asymmetry.** `error()` takes `errorCls`
   parameter (`_src/logger.py:122`); `critical()` does not (line 137 hardcodes
   `RuntimeError`). Port verbatim — do not "normalise".

6. **`configure()` swallows file-not-found silently** (`ngcsimlib/__init__.py:38-43`).
   The user-visible feedback is gone (warn-line is commented out, line 39-43).
   Port verbatim. Document that callers who want feedback should explicitly call
   `init_config(path)` themselves.

7. **`_src/__init__.py` is entirely commented out** (lines 1-76). The Julia port
   should NOT have a `_src.jl` mirror — the contents are dead. The functional
   logic (preload_modules, configure) lives in (a) `ngcsimlib/__init__.py` for
   `configure`, and (b) nowhere for `preload_modules` (entirely orphaned).
   `preload_modules` is therefore a **Phase-A non-goal**.

8. **`utils/__init__.py` is 0 bytes.** No re-exports. Julia port's `Utils/` must
   match — no auto-export. Callers `using NGCSimLib.Utils.IO: make_unique_path`
   explicitly.

9. **`_Loaded_Modules` / `_Loaded_Attributes` cache invalidation.** Caches grow
   monotonically. No eviction. Long-running processes could leak. Not a correctness
   bug; document as limitation.

10. **`make_unique_path` uses `print`, not `logger.info`** (lines 25, 29). Two
    print calls escape the logging layer. Port verbatim with `println(...)` —
    but note that this means `hide_console=True` in the logging config does not
    suppress these messages. Hazard for clean-output users; flag for Phase-B.
