# NGCSimLib — Phase A Spec 02: `context` module

**Source tree:** `ngc-sim-lib/ngcsimlib/_src/context/`
**Files inspected (every line read):**

| File | Bytes |
|---|---|
| `__init__.py` | 364 |
| `context.py` | 14 532 |
| `context_manager.py` | 7 807 |
| `contextObjectDecorators.py` | 543 |
| `contextAwareObject.py` | 1 795 |
| `contextAwareObjectMeta.py` | 2 269 |

This module is the central orchestration/scope mechanism of ngcsimlib. Everything
else (Component, Compartment, Process, Op) registers into a `Context`. The runtime
keeps a **single global hierarchy** of named contexts and a mutable "current path"
that determines which context auto-captures new objects.

---

## Purpose (the conceptual model)

A `Context` is **simultaneously three things**:

1. **A scope.** Entered via Python `with ctx: ...`. While inside, any
   `ContextAwareObject` constructed has its `_type`-bucket entry registered into
   `ctx.objects`. On exit, the context **recompiles** every compilable object it
   owns, in priority order (`context.py:65–73`).

2. **A named node in a tree.** Identified by a colon-separated path
   (e.g. `"world:agent:cortex"`). All contexts ever created live in a flat
   global dict keyed by their joined path (`context_manager.py:11, 197`).
   Nesting comes from the *current path* the manager carries while a `with`
   block is open; a new `Context("foo")` inside one is created at
   `<parent>:foo`.

3. **A container for the compiled model.** Holds `objects: Dict[_type → Dict[name → obj]]`
   and `_connections: Dict[destination_compartment_root → source]` (`context.py:62–63`).
   Knows how to serialize itself (and every object in it) to a directory of JSON
   files, and how to load itself back (`save_to_json` / `load`).

The *current context* is determined exclusively by the `__context_manager`'s
`current_path` — a **mutable list of strings**. There is one singleton manager
instance, `global_context_manager` (`context_manager.py:234`), imported by every
other file in the module.

Lifecycle in plain English:

```
Context("world")               # registered at path "world"; not current
with Context("world") as w:    # __enter__: push "world" onto current_path
    Component(name="x")        # auto-registered in w
    with Context("agent") as a:#  registers at "world:agent"; pushes "agent"
        Component(name="y")    #  auto-registered in a
    # __exit__ a: recompile a, pop "agent"
# __exit__ w: recompile w, pop "world"
```

The on-exit recompile is what makes the `with` block load-bearing — the JIT/parse
machinery (`parser.compileObject`) only runs after the user has finished defining
the model.

---

## Public API

### Module exports — `__init__.py:1–10`

```python
from .contextAwareObject import ContextAwareObject
from .context import Context, ContextObjectTypes
from .context_manager import global_context_manager
from .contextObjectDecorators import component, process
```

Comment at `__init__.py:3` is load-bearing: `Context` MUST be imported *after*
`ContextAwareObject` because of circular `TYPE_CHECKING` references — note for
the Julia port.

---

### `class ContextObjectTypes(Enum)` — `context.py:20–28`

```python
class ContextObjectTypes(Enum):
    component = "component"
    process   = "process"
```

A two-value enum. The string value (not the enum member) is what eventually
keys `ctx.objects` (`context.py:142–143` normalizes enum → string). Custom
unknown types are tolerated with a warning (`context.py:132–141`).

---

### `class Context(object)` — `context.py:31–356`

#### `Context.__new__(cls, name, *args, **kwargs)` — `context.py:44–53`

**Custom allocator with global-uniqueness semantics.** Computes
`targetPath = gcm.append_path(addition=name)` (i.e. *current path* `+ ":" + name`),
then:

- if a context already exists at that path → **return the existing instance**
  (essentially a get-or-create singleton keyed by path),
- else allocate, register with `gcm.register_context_local(name, instance)`,
  set `instance.path = targetPath` and `instance.__previous_path = None`.

This means `Context("foo")` is **idempotent**: two calls in the same scope
return the same object, and `__init__` will see `_initialized` already set
on the second call and short-circuit.

#### `Context.__init__(self, name)` — `context.py:55–63`

Guarded by `self._initialized` so repeat construction is a no-op.

Fields set on first construction:

| Field | Type | Purpose |
|---|---|---|
| `_initialized` | `True` | re-entry guard |
| `name` | `str` | display name (NOT the path) |
| `objects` | `Dict[str, Dict[str, ContextAwareObject]]` | typed bucket map |
| `_connections` | `Dict[str, Union[Compartment, BaseOp]]` | dest-root → source |
| `path` | `str` | (set in `__new__`) joined path |
| `__previous_path` | `Optional[str]` | enter/exit stack of size 1 |

#### `Context.__enter__(self)` — `context.py:65–68`

```python
self.__previous_path = gcm.current_path   # snapshot
gcm.step_to(self.path)                    # become current
return self
```

#### `Context.__exit__(self, exc_type, exc_val, exc_tb)` — `context.py:70–73`

```python
self.recompile()                       # ← BEFORE restoring path
gcm.step_to(self.__previous_path)
self.__previous_path = None
```

**Hazard:** `recompile()` is called *unconditionally*, even if `exc_type` is
not None. The exit handler does not consult the exception args; it always
recompiles and always restores. There is no try/finally — if `recompile()`
raises, path restoration is skipped, leaving the manager in a corrupt state.
(See "Open questions / hazards" below.)

#### `Context.recompile(self) -> None` — `context.py:75–103`

Iterates every `_type` bucket, every object in that bucket, and collects those
with attribute `_is_compilable == True`. For each such object, reads `_priority`
(default 0). Builds `priorities: Dict[int, List[obj]]`, then iterates priorities
sorted **descending** (`reverse=True`) and calls `obj.compile()` on each.

Comments at `context.py:81–86`:

- 0 is the default priority.
- −1 is reserved for processes / objects that expect everything else to compile
  first (so they run last — lower priority sorted last).
- Custom (non-metaclass, non-decorator) objects can opt-in by setting
  `_is_compilable` and `_priority` themselves.

#### `Context.registerObj(self, obj) -> bool` — `context.py:105–155`

Called by `ContextAwareObjectMeta.__call__` after construction. Pulls
`_type = getattr(obj, "_type", None)`:

- `_type is None` → `warn(...)`, return False.
- `_type` not an enum member, not already a key in `self.objects`, and not a
  string matching an enum name → `warn(...)` (still proceeds).
- normalize `_type` to its string value (`context.py:142–143`).
- ensure bucket exists (`context.py:145–146`).
- duplicate-name detection at `context.py:148–152` — **NOTE:** the check is
  `self.objects[_type].get(obj) is not None`, indexing by the object itself
  (`__hash__`), not by `obj.name`. The error message claims to be checking
  name collisions but the code keys by object identity. This is almost
  certainly a bug; the next line stores by `obj.name`. Document as-is, but
  the Julia port should key by `name` for both store and check.
- store `self.objects[_type][obj.name] = obj`; return True.

#### `Context.get_objects_by_type(self, objectType) -> Dict[str, obj]` — `context.py:157–173`

Returns `self.objects.get(_type, {})`. Accepts enum or string.

#### `Context.get_objects(self, *object_names, objectType, unwrap=True)` — `context.py:175–218`

Multi-name lookup. Behavior matrix:

| `len(names)` | `unwrap` | returns |
|---|---|---|
| 0 | True | `None` |
| 0 | False | `[]` |
| 1 | True | the single object or `None` |
| 1 | False | `[obj_or_None]` |
| N | any | `[obj_or_None, ...]` |

Emits a warn per missing name (`context.py:211–214`).

#### `Context.get_components(self, *component_names, unwrap=True)` — `context.py:220–225`

Thin alias: `get_objects(..., objectType=ContextObjectTypes.component, unwrap=...)`.
(There is no symmetric `get_processes` — note for the port to add it for
parity.)

#### `Context.add_connection(self, source, destination)` — `context.py:227–228`

```python
self._connections[destination.root] = source
```

`destination` must be a `Compartment` (has `.root`). `source` is `Compartment`
or `BaseOp` (`context.py:227` signature, used at `context.py:299–303` during
save). One destination → one source; new calls overwrite.

#### `Context.save_to_json(self, directory, model_name=None, custom_save=True, overwrite=False) -> None` — `context.py:230–306`

Layout produced under `<directory>/<model_name>/`:

```
contextData.json                 # {"types": [...], "path": self.path}
<type1>/
    roots.json                   # {obj_name: {args, kwargs, modulePath, ...obj.to_json()}}
    custom/                      # exists iff some obj has callable .save
        ...                      # whatever each obj.save(custom_dir) writes
<type2>/
    ...
connections.json                 # {dest_root: target_str | source_op.to_json()}
```

Notable behaviors:

- `model_name` defaults to `self.name` then `make_safe_filename(model_name)`.
- `overwrite=True` first manually deletes every file/subdir under
  `<directory>/<model_name>/` (in a try/except, printing failures) **then**
  also calls `shutil.rmtree`. The manual loop is redundant; the
  `shutil.rmtree` would handle it. Document as-is.
- `make_unique_path` is called *after* the overwrite branch — so if
  `overwrite=True` cleared `<dir>/<name>`, `make_unique_path` will hand back
  exactly that path. If `overwrite=False` and the path already exists,
  `make_unique_path` returns a uuid-suffixed variant.
- Each object's `to_json()` is merged into a dict with `modulePath` from
  `modManager.resolve_public_import(obj)` — used on load to re-import.
- A connection where `source` is a `Compartment` is serialized as the source's
  `.target` (a string); a `BaseOp` source is serialized via its `.to_json()`.

#### `Context.load(cls, directory, module_name) -> Context` — `classmethod` `context.py:308–356`

Reverse of save. Returns a `Context`. If a context already exists at the
target path, **warns and returns the existing one** without loading.

Algorithm:

1. Read `contextData.json`; extract stored `path`.
2. **Open a `with cls(metaData["path"]) as ctx:` block** — meaning load happens
   inside an entered scope so newly-constructed objects auto-register.
3. For each declared `_type`, read `<type>/roots.json`. For each entry:
   - import the class by `modulePath` via `modManager.import_module(...)`.
   - construct it with `(*args, **kwargs)` from the JSON.
   - **append** to `delayed_load` with `_priority` (default 0).
4. Sort `delayed_load` by priority descending.
5. For each: call `obj.from_json(data)` if present, then `obj.load(custom_dir)`
   if present.
6. Read `connections.json`. For each `dest_root → target`:
   - `dest = global_state_manager.get_compartment(dest_root)`
   - if `target` is a `str`: `dest.target = target`
   - else: `dest.target = BaseOp.load_op(target)`
7. The `with` block exits, which triggers `recompile()`.

---

### `class __context_manager` — `context_manager.py:9–232` (singleton)

The instance is `global_context_manager` (`context_manager.py:234`). The class
name has a double-underscore prefix, which in Python is name-mangled — i.e.
intended to be private-by-convention. Only the singleton is imported.

#### Constructor — `context_manager.py:10–13`

```python
def __init__(self, seperator: str = ":"):
    self.__contexts: Dict[str, "Context"] = {}
    self.__current_path: List[str] = []
    self.__seperator: str = seperator
```

(`seperator` [sic] — keep typo as-is in name, fix in Julia.)

#### Properties

- `current_context` — `context_manager.py:15–21` — `self.__contexts.get(self.join_path(), None)`.
  Returns the context at the *current* path, or `None`.
- `current_location` — `:23–30` — last segment of current path; `""` if root.
- `current_path` — `:32–38` — current path joined as string.

#### Mutation methods

- `clear()` — `:40–45` — wipes all registered contexts. Warning in docstring.
- `step(location, catch_empty=True) -> bool` — `:47–63` — append one segment.
  Returns True if a context exists at the new path; warns if not. **Always**
  mutates the path either way.
- `step_back() -> bool` — `:65–73` — pop one segment. Returns False at root
  (no-op).
- `step_to(path) -> bool` — `:75–91` — split `path` into segments, replace
  `self.__current_path[:]` (in-place). Returns True always; warns if no
  context exists at the new path. (NB: the docstring says "Returns: if there
  is a registered context" but the implementation returns True
  unconditionally at line 91 — bug-or-feature, port faithfully but document.)

#### Lookup methods

- `get_context(path) -> Optional[Context]` — `:93–103` — dict lookup.
- `exists(path=None) -> bool` — `:105–118` — root path `""` always exists;
  otherwise dict membership.

#### Path manipulation

- `join_path(path=None) -> str` — `:120–133`. `None` → current; `str` →
  unchanged; `list` → `":".join(...)`.
- `split_path(path=None) -> List[str]` — `:135–148`. `None` → current
  (returns the live list — aliasing hazard, not a copy); `list` → unchanged
  (also alias); `str` → `path.split(":")`.
- `append_path(rootPath=None, addition=None) -> str` — `:150–174`. Edge cases:
  - `addition is None` → just `join_path(rootPath)`.
  - `rootPath` empty → returns `addition` (or its join) directly with no
    leading separator.
  - both present → `<root> : <addition>`.

#### Registration

- `register_context(path, context, overwrite=False)` — `:176–197`:
  - if exists and not overwrite → warn and abort (returns falsy via no
    explicit return — actually `None`, not `False`).
  - if exists and overwrite → warn and proceed.
  - assigns `self.__contexts[path] = context`. **Note:** uses `path` (raw
    argument, may be `list`!) as the dict key, NOT `_path`. Lookup elsewhere
    uses joined strings — port should normalize to string.
- `register_context_local(local_path, context, overwrite=True) -> bool` — `:199–213`.
  Default overwrite is **True** here (different from `register_context`).
  Delegates to `register_context(append_path(None, local_path), context, overwrite)`.
  Called by `Context.__new__` (`context.py:49`).
- `remove_context(path)` — `:215–232` — del-from-dict with logging.

---

### `class ContextObjectDecorators` — `contextObjectDecorators.py:3–17`

Two `@staticmethod` decorators:

```python
@staticmethod
def component(cls):
    cls._type = ContextObjectTypes.component
    return cls

@staticmethod
def process(cls):
    cls._type = ContextObjectTypes.process
    return cls
```

Module-level aliases at `:19–20`:

```python
component = ContextObjectDecorators.component
process   = ContextObjectDecorators.process
```

They do **nothing** at runtime except set a class-level attribute `_type`.
The metaclass's `__call__` later reads `_type` via `registerObj`.

---

### `class ContextAwareObject(metaclass=ContextAwareObjectMeta)` — `contextAwareObject.py:9–52`

The recommended base class for user objects.

#### `__init__(self, name)` — `:16–18`

```python
self.name = name
self.context_path = gcm.current_path
```

Records the path of the context that built it (a snapshot at construction
time).

#### `to_json(self) -> Dict[str, Any]` — `:20–45`

Serializes positional + keyword args captured by the metaclass into
`{"args": [...], "kwargs": {...}}`. Each value is attempted via
`json.dumps`; on failure, the arg is **silently dropped** with a warn.

Depends on `self._args` and `self._kwargs` being set — done by the
metaclass `__call__` at `contextAwareObjectMeta.py:55–56`.

#### `compile(self) -> None` — `:47–52`

```python
def compile(self):
    compileObject(self)
```

`compileObject` is `ngcsimlib/_src/parser/utils.py:136–157`:

```python
def compileObject(obj):
    deferred_compile = []
    for name in dir(obj):
        attr = getattr(obj, name)
        if isinstance(attr, _methodWrapper):
            attr = attr._method
        if hasattr(attr, "_is_compilable") and not inspect.isclass(attr):
            if isinstance(type(attr), ContextAwareObjectMeta):
                compileObject(attr)            # recurse into nested aware objs
            else:
                deferred_compile.append(attr)
    for attr in deferred_compile:
        parse_method(obj, attr)
```

Out-of-scope here, but the port's Compartment/Component agents will need it.

---

### `class ContextAwareObjectMeta(type)` — `contextAwareObjectMeta.py:26–70`

A metaclass — **the heart of the auto-registration mechanism.**

#### `extract_name(cls, args, kwargs)` — `:8–23`

Uses `inspect.signature(cls.__init__)` to do a partial bind and pull out
whatever value the caller passed (or default) for the parameter `name`.
Handles a custom deprecation wrapper: if `init._is_deprecated`, walks
`init._original` to find the real init.

Returns the bound `name` value or `None` if no `name` parameter exists.

#### `__new__(cls, name, bases, attrs)` — `:27–41`

Injects two methods into the class being defined **iff they aren't already
declared by the user**:

```python
if '__enter__' not in attrs:
    def __enter__(self):
        gcm.step(self._inferred_name, catch_empty=False)
    attrs['__enter__'] = __enter__

if '__exit__' not in attrs:
    def __exit__(self, type, value, traceback):
        gcm.step_back()
    attrs['__exit__'] = __exit__
```

So every ContextAwareObject becomes itself a context manager, pushing
*its own name* onto the path while its `__init__` runs.

#### `__call__(cls, *args, **kwargs)` — `:48–70`

This is the meta-`__init__` invoked when you write `MyClass(...)`:

```python
def __call__(cls, *args, **kwargs):
    obj = cls.__new__(cls, *args, **kwargs)
    obj._inferred_name = extract_name(cls, args, kwargs)

    with obj:                            # pushes obj._inferred_name
        cls.__init__(obj, *args, **kwargs)
        obj._args   = args
        obj._kwargs = kwargs

        if not hasattr(obj, 'name'):
            error(...)

        if hasattr(obj, "compartments") and ...:
            for (comp_name, comp) in obj.compartments:
                if hasattr(comp, "_setup") and callable(comp._setup):
                    comp._setup(comp_name, gcm.current_path)

    contextRef = gcm.current_context     # NOTE: AFTER `with obj` exits
    if contextRef is not None:
        contextRef.registerObj(obj)
    return obj
```

Key sequence:

1. Allocate instance.
2. Pre-extract `name` from the call so we can step into a path before init runs.
3. **Enter `obj` itself as a context manager** — this pushes `_inferred_name`
   onto `gcm.current_path`. While true, anything created inside `__init__`
   sees a deeper path.
4. Run user's `__init__`.
5. Stash the original constructor args for later JSON serialization.
6. Validate `name`.
7. If the object exposes `compartments` (iterable of `(name, compartment)`
   tuples), call `comp._setup(comp_name, gcm.current_path)` on each. This
   is the **handshake with the Compartment module** — compartments learn
   their fully-qualified path here. Crosses module boundary — flag for the
   other Phase A agent.
8. Exit `obj`'s context (pop the name).
9. NOW look up `current_context` (which is the *enclosing* `Context`, since
   we popped) and call `registerObj(obj)` on it.

This is why the `Component` is registered in the *enclosing* `Context`, not
in itself: by the time `registerObj` is called, the path has been popped
back. **This is the critical scope invariant.**

---

## Internal classes / functions

There are no "internal" Python objects in this module distinct from the
public ones above; private-by-convention `_foo` is exposed throughout
(e.g. `_type`, `_is_compilable`, `_priority`, `_args`, `_kwargs`,
`_inferred_name`, `_setup`). Treat all of these as part of the protocol —
the Julia port will need fields/traits for each.

Implicit "private" surface a Julia port still has to model:

| Name | Where set | Reader | Meaning |
|---|---|---|---|
| `_type` | decorator (`contextObjectDecorators.py:10,15`) | `Context.registerObj` (`context.py:123`) | bucket key |
| `_is_compilable` | by user/decorator (out of module) | `Context.recompile` (`context.py:92`); `compileObject` (`parser/utils.py:150`) | opt into compile |
| `_priority` | by user/decorator (out of module) | `Context.recompile` (`context.py:93`); `Context.load` (`context.py:334,337`) | compile order, descending |
| `_args`, `_kwargs` | meta `__call__` (`Meta.py:55–56`) | `to_json` (`ContextAwareObject.py:28–36`) | replay constructor on load |
| `_inferred_name` | meta `__call__` (`Meta.py:50`) | injected `__enter__` (`Meta.py:30`) | path segment |
| `_initialized` | `Context.__init__` (`context.py:59`) | `Context.__init__` guard (`:56`) | dedupe `__init__` on cached instance |
| `__previous_path` | `Context.__enter__` (`:66`) | `Context.__exit__` (`:72`) | enter/exit stack of depth 1 |

---

## Data structures + invariants

### `Context` instance

```
.name            : str                                       # user-given
.path            : str                                       # absolute, "a:b:c"
.objects         : Dict[str(=_type) → Dict[str(=name) → obj]]
._connections    : Dict[str(=dest.root) → Compartment | BaseOp]
._initialized    : True                                      # singleton guard
.__previous_path : Optional[str]                             # name-mangled
```

### `__context_manager` singleton

```
.__contexts      : Dict[str(=joined path) → Context]   # global registry
.__current_path  : List[str]                           # mutable stack
.__seperator     : str = ":"                           # immutable after init
```

### Ownership

- The **manager owns** all `Context` instances (strong refs).
- A `Context` **owns** all its `ContextAwareObject` instances (via `objects`).
- A `ContextAwareObject` does **not** back-reference its context; instead it
  stores `context_path: str` (`contextAwareObject.py:18`) — a path, not a
  pointer. Resolution at runtime: `gcm.get_context(obj.context_path)`.
- The `_connections` map references `Compartment`s and `BaseOp`s by object,
  not by path.

### Lifecycle

- **Create:** `Context(name)` → `gcm.register_context_local` → strong ref in
  manager. The instance is **kept alive by the manager forever** unless
  explicitly `gcm.remove_context(path)`'d. There is no automatic teardown.
- **Mutate:** only via `with ctx: ...` (push current_path, build objects,
  pop, recompile).
- **Teardown:** `gcm.remove_context(path)` only. There is no `Context.close()`.
- **Persistence:** `save_to_json` / `load`.

### Thread safety

**None.** The manager is a process-global singleton with mutable
`__current_path` and `__contexts`. Concurrent `with ctx:` blocks in different
threads will race. The port should decide: thread-local current path? Lock?
Pass-by-arg? (See "Julia translation notes".)

### Invariants the code assumes (worth restating)

- `Context.path` is set exactly once in `__new__` and never reassigned.
- Two `Context` instances cannot share a path (enforced by get-or-create in
  `__new__`).
- Within a `with` block, `gcm.current_context is self`.
- Recompile runs **before** path restoration on exit.
- `ContextAwareObject._inferred_name` exists by the time the injected
  `__enter__` runs — set in meta `__call__` before `with obj:`.

---

## Metaclass + decorator behavior

### `ContextAwareObjectMeta` injects

For every class that uses this metaclass:

- a default `__enter__` that pushes `self._inferred_name` onto the manager
  (only if the user didn't already define `__enter__`),
- a default `__exit__` that pops one (only if user didn't define one),
- a custom `__call__` that:
  - allocates,
  - extracts `name` from the bound init signature,
  - enters `self` (pushing its name onto the path),
  - runs user `__init__`,
  - captures `_args`/`_kwargs`,
  - sets up child compartments,
  - exits `self`,
  - registers in the **parent** `Context`.

### `component` / `process` decorators inject

- `cls._type = ContextObjectTypes.component` (or `.process`).

That's all they do. They are **independent** of the metaclass — a user could
write a plain class (no metaclass), decorate it with `@component`, and as
long as they manually call `registerObj`, the type bucket will work. The
metaclass machinery just automates the registration step.

### Julia equivalents

| Python mechanism | Julia mechanism |
|---|---|
| Metaclass `__new__` injecting methods | `@context_aware` macro that lowers a `struct` definition into `struct + Base.enter!/exit!` methods, or a `ContextAware{T}` parametric wrapper + dispatched `enter!(obj)`/`exit!(obj)`. |
| Metaclass `__call__` wrapping construction | A constructor macro `@build` that expands `Foo(args...)` to `build_aware(Foo, args...)`, where `build_aware` allocates, pushes name, runs `Base.invokelatest(Foo, args...)` (or a registered `init!`), pops, registers. Cleaner: a function `make_aware(T, args...; name=...)` that all leaf types call from their outer constructor. |
| `@component` / `@process` decorators | Trait-based: define `context_type(::Type{<:MyComp}) = :component`. Or a macro `@component struct MyComp ... end` that emits `context_type(::Type{MyComp}) = :component`. Storing the type tag as a Holy trait is idiomatic and zero-cost. |
| Python `with ctx: ...` block | Julia `with_context(ctx) do ... end` taking a `do`-block, OR a macro `@within ctx begin ... end`. The `do`-block form is more idiomatic and exception-safe via `try/finally`. |

Concrete proposed core types (sketch):

```julia
abstract type AbstractContextAwareObject end

@enum ContextObjectType COMPONENT PROCESS

# Default; a @component macro / explicit override can change this.
context_type(::Type{<:AbstractContextAwareObject}) = :unknown

mutable struct Context
    name::String
    path::String
    objects::Dict{Symbol, Dict{String, AbstractContextAwareObject}}
    connections::Dict{String, Any}   # dest_root => Compartment|BaseOp
    initialized::Bool
    previous_path::Union{Nothing, String}
end

mutable struct ContextManager
    contexts::Dict{String, Context}
    current_path::Vector{String}
    separator::String
end

const GLOBAL_CONTEXT_MANAGER = ContextManager(Dict(), String[], ":")
```

(The port should debate: `mutable struct` vs `Ref`-wrapped immutable, and
whether `current_path` should be `task_local_storage()`-backed.)

---

## External dependencies

| Import (Python) | Used at | What for | Julia equivalent |
|---|---|---|---|
| `json` | `context.py:1`, `contextAwareObject.py:1` | save/load JSON files; `json.dumps` probe for serializability | `JSON3.jl` or `JSON.jl` (probe via `try JSON3.write(v); true catch; false end`) |
| `os`, `shutil` | `context.py:12` | mkdir, rmtree, isdir, listdir, unlink | `mkpath`, `rm(...; recursive=true)`, `isdir`, `readdir`, `rm(file)` |
| `typing` (`TYPE_CHECKING`, `Union`, `List`, `Dict`, `Tuple`) | both | type hints only | n/a — Julia has native types |
| `enum.Enum` | `context.py:11` | `ContextObjectTypes` | `@enum` or a `Symbol`-based tag |
| `inspect` | `contextAwareObjectMeta.py:1` | `inspect.signature(init)` to extract `name` param | Julia: `methods(T)` + reflection on the constructor; or convention: require `name` as keyword arg `name::String`, read it directly from `kwargs`. **Recommend the convention path** to avoid fragile reflection. |
| `collections.abc.Iterable` | `contextAwareObjectMeta.py:5` | duck-typing `obj.compartments` | Julia: just iterate; check `applicable(iterate, x)` or rely on AbstractVector dispatch. |
| `ngcsimlib.logger` (`warn`, `info`, `error`) | both | structured logging | port the logger module first (it's tiny). Use Julia's `Logging` stdlib under the hood. |
| `ngcsimlib._src.utils.io` (`make_unique_path`, `make_safe_filename`) | `context.py:5` | filename sanitization, uuid-suffix paths | Port `io.py` (small) to NGCSimLib `utils/io.jl`. |
| `ngcsimlib._src.modules.modules_manager.modules_manager` | `context.py:6` (`modManager`) | `resolve_public_import(obj)` → module path string; `import_module(path)` → re-import class on load | Julia: replace with explicit type registry (`Dict{String, Type}`) since Julia's module system is not symmetric with Python imports. **Critical port decision** — see Open Questions. |
| `ngcsimlib._src.operations.BaseOp.BaseOp` | `context.py:7` | type narrowing in save; `BaseOp.load_op(target)` in load | Out-of-scope here; the Ops/Process Phase A agent owns it. The port needs `load_op(d::Dict)::AbstractOp`. |
| `ngcsimlib._src.global_state.manager.global_state_manager` | `context.py:9` | `get_compartment(root)` during load | Out-of-scope; flag overlap with Compartment Phase A agent. |
| `ngcsimlib._src.compartment.compartment.Compartment` | `context.py:14` | `isinstance(source, Compartment)` narrowing in save | Compartment agent's territory. |
| `ngcsimlib._src.parser.utils.compileObject` | `contextAwareObject.py:6` | walks the object's attrs and calls `parse_method` on every `_is_compilable` method | Out-of-scope; parser Phase A agent owns. The port just calls `compile_object!(obj)`. |

---

## Julia translation notes

### Naming

- Strip `__` and `_` leading underscores; use lower-snake. `_type` →
  `context_type` (the field), or store as a function-trait
  `context_type(::Type{T})`.
- Pythonic doubled-private `__contexts` → just `contexts` (field). Julia
  has no name mangling.
- Fix the `seperator` typo to `separator`.

### Class hierarchy

```julia
abstract type AbstractContextAwareObject end
mutable struct Context end                  # NOT subtype of the above
mutable struct ContextManager end           # singleton struct
```

`Context` is **not** a `ContextAwareObject` in Python either — they are
parallel hierarchies.

### Metaclass → Julia options

Three options. **Recommended:** option (a) plus a default outer constructor
helper.

(a) **Macro that lowers struct + outer constructor.**

```julia
@context_aware @component mutable struct LeakyIntegrator <: AbstractContextAwareObject
    name::String
    tau::Float64
    # ... user fields
    args::Tuple
    kwargs::Dict{Symbol,Any}
    inferred_name::String
end
```

The macro expands to:

- the struct as written,
- `context_type(::Type{LeakyIntegrator}) = :component`,
- an outer constructor `LeakyIntegrator(args...; kwargs...)` that:
  1. allocates an "incomplete" instance (using `Core.eval`/`Base.copy` tricks
     or by deferring field init — see below),
  2. pushes `name` onto the manager,
  3. fills in fields,
  4. pops the manager,
  5. registers in the enclosing context.

(b) **A `make_aware(T, args...)` function** the user calls explicitly from
their outer constructor:

```julia
function MyComp(name; kw...)
    make_aware(MyComp, name; kw...) do obj
        obj.tau = kw[:tau]
        # …
    end
end
```

The `make_aware(T, name; kw...)` helper does the push/init/pop/register
dance. Simpler to debug than a macro; slightly more boilerplate per type.

(c) **Use `__init__`-style external registration via `@__MODULE__`.**
Worst option — produces global mutable state with no compile-time guard.

### Context manager (`with`) → `do`-block helper

```julia
function with_context(f::Function, ctx::Context)
    previous = current_path(GLOBAL_CONTEXT_MANAGER)
    ctx.previous_path = previous
    step_to!(GLOBAL_CONTEXT_MANAGER, ctx.path)
    try
        f(ctx)
    finally
        recompile!(ctx)                             # see hazard below
        step_to!(GLOBAL_CONTEXT_MANAGER, previous)
        ctx.previous_path = nothing
    end
end

# Usage:
with_context(Context("world")) do w
    LeakyIntegrator("x"; tau=10.0)
    with_context(Context("agent")) do a
        # ...
    end
end
```

A macro form `@within Context("world") begin ... end` is also fine, but
`do`-block is more idiomatic.

**Decision point:** the Python order is `recompile()` THEN `step_to(prev)`.
If you `try/finally` literally, an exception in the body will trigger
`recompile()` from inside `finally`, and a failing recompile will throw OUT
of the `finally`, masking the original exception. Recommendation: catch
exceptions from `recompile!` inside `finally`, log them, and re-raise the
original. Or: skip recompile on exception (deviates from upstream — call
this out in design doc).

### Global state — where to hold it

Python uses a true module-global singleton. Julia options:

1. `const GLOBAL_CONTEXT_MANAGER = ContextManager(...)` — simplest, mirrors
   Python, breaks tests that need isolation, NOT thread-safe.
2. `task_local_storage()` for `current_path`; module-global for
   `contexts` registry. Solves common race (one task per simulation), keeps
   global lookup.
3. `ScopedValues` (Julia 1.11+) for the current path. Cleanest if we can
   require ≥1.11.
4. Pass `ContextManager` explicitly through every constructor. Most pure;
   most invasive to user code.

**Recommendation:** start with option 1 for parity, build option 3 behind a
feature flag once tests exist. Document in design doc.

### Concrete proposed Julia type definitions

```julia
# context_manager.jl
mutable struct ContextManager
    contexts::Dict{String, Any}              # Any = Context (forward decl)
    current_path::Vector{String}
    separator::String
end

ContextManager(; separator::String=":") =
    ContextManager(Dict{String,Any}(), String[], separator)

const GLOBAL_CONTEXT_MANAGER = ContextManager()

function current_path(m::ContextManager)::String
    join(m.current_path, m.separator)
end
function current_location(m::ContextManager)::String
    isempty(m.current_path) ? "" : m.current_path[end]
end
function current_context(m::ContextManager)::Union{Nothing,Any}
    get(m.contexts, current_path(m), nothing)
end

step!(m::ContextManager, location::AbstractString) =
    push!(m.current_path, String(location))
step_back!(m::ContextManager) =
    isempty(m.current_path) ? false : (pop!(m.current_path); true)
function step_to!(m::ContextManager, path::AbstractString)
    empty!(m.current_path)
    if !isempty(path)
        append!(m.current_path, split(path, m.separator))
    end
    return true
end
exists(m::ContextManager, path::AbstractString="") =
    isempty(path) ? true : haskey(m.contexts, path)
function append_path(m::ContextManager, root::Union{Nothing,String}=nothing,
                     addition::Union{Nothing,String}=nothing)
    base = root === nothing ? current_path(m) : root
    addition === nothing && return base
    isempty(base) && return addition
    base * m.separator * addition
end

function register_context!(m::ContextManager, path::String, ctx;
                           overwrite::Bool=false)
    if haskey(m.contexts, path)
        if !overwrite
            @warn "Attempted to overwrite existing context at $path. Aborting."
            return false
        end
        @warn "Overwriting existing context at $path."
    end
    m.contexts[path] = ctx
    return true
end

register_context_local!(m::ContextManager, local_path::String, ctx;
                        overwrite::Bool=true) =
    register_context!(m, append_path(m, nothing, local_path), ctx;
                      overwrite=overwrite)
```

```julia
# context.jl
mutable struct Context
    name::String
    path::String
    objects::Dict{Symbol, Dict{String, AbstractContextAwareObject}}
    connections::Dict{String, Any}    # dest_root => source
    previous_path::Union{Nothing, String}
end

# Idempotent get-or-create constructor, mirroring Python __new__/__init__.
function Context(name::String;
                 mgr::ContextManager=GLOBAL_CONTEXT_MANAGER)
    target = append_path(mgr, nothing, name)
    if exists(mgr, target)
        return mgr.contexts[target]
    end
    ctx = Context(name, target,
                  Dict{Symbol,Dict{String,AbstractContextAwareObject}}(),
                  Dict{String,Any}(),
                  nothing)
    register_context_local!(mgr, name, ctx; overwrite=true)
    return ctx
end

function with_context(f, ctx::Context;
                      mgr::ContextManager=GLOBAL_CONTEXT_MANAGER)
    ctx.previous_path = current_path(mgr)
    step_to!(mgr, ctx.path)
    try
        return f(ctx)
    finally
        try
            recompile!(ctx)
        catch err
            @error "recompile! threw" exception=(err, catch_backtrace())
        end
        step_to!(mgr, ctx.previous_path)
        ctx.previous_path = nothing
    end
end

function register_obj!(ctx::Context, obj::AbstractContextAwareObject)
    t = context_type(typeof(obj))            # :component / :process / :unknown
    if t === :unknown
        @warn "Object $(name_of(obj)) has no _type."
        return false
    end
    bucket = get!(ctx.objects, t, Dict{String,AbstractContextAwareObject}())
    n = name_of(obj)
    if haskey(bucket, n)
        @warn "Duplicate name $n in context type $t; aborting."
        return false
    end
    bucket[n] = obj
    return true
end

function recompile!(ctx::Context)
    by_pri = Dict{Int,Vector{AbstractContextAwareObject}}()
    for (_, bucket) in ctx.objects
        for (_, obj) in bucket
            is_compilable(obj) || continue
            p = priority(obj)
            push!(get!(by_pri, p, AbstractContextAwareObject[]), obj)
        end
    end
    for k in sort!(collect(keys(by_pri)); rev=true)
        for obj in by_pri[k]
            compile!(obj)
        end
    end
end

# Trait API the rest of the library implements:
is_compilable(::AbstractContextAwareObject) = false
priority(::AbstractContextAwareObject)      = 0
name_of(o::AbstractContextAwareObject)      = o.name
```

(The `compile!`, `is_compilable`, `priority` traits live in
`ContextAwareObject` and are overridden by the Compartment/Component agent's
types.)

---

## State / scope behavior (critical)

This is where naive ports break. Document the **exact** mutation sequence.

### On `Context("foo")` outside any `with`

```
target := append_path(current_path(""), "foo") = "foo"
- exists("foo")? if yes → return existing.
- else: instance.path = "foo"
        gcm.contexts["foo"] = instance
- current_path unchanged.
```

### On entering `with Context("foo") as f:`

```
__enter__:
    self.previous_path := gcm.current_path     # snapshot, e.g. ""
    gcm.step_to("foo")                         # current_path := ["foo"]
```

### Building a leaf inside that block — `LeakyIntegrator("x")`

```
metaclass __call__:
    obj = LeakyIntegrator.__new__(...)
    obj._inferred_name := "x"               # extracted from init kwargs
    obj.__enter__():                        # injected by meta
        gcm.step("x", catch_empty=False)    # current_path := ["foo","x"]
    LeakyIntegrator.__init__(obj, "x"):
        # user code; any nested aware objects will register at foo:x:...
    obj._args, obj._kwargs := args, kwargs
    if obj.compartments:
        for (cname, comp) in obj.compartments:
            comp._setup(cname, gcm.current_path)   # current path = "foo:x"
    obj.__exit__():                         # injected by meta
        gcm.step_back()                     # current_path := ["foo"]
    ctx = gcm.current_context               # ctx = the Context at "foo"
    ctx.registerObj(obj)                    # registers under "foo" not "foo:x"
```

So the **registered location** of a Component is the path of the **enclosing
Context**, but `obj.context_path` (set in `ContextAwareObject.__init__`) is
the path that was current **during** init — `"foo:x"`. Two paths per object.

### On exiting `with Context("foo") as f:`

```
__exit__:
    f.recompile()                            # walks f.objects, sorts by _priority desc, calls .compile()
    gcm.step_to(f.previous_path)             # current_path := []
    f.previous_path := None
```

### Nested contexts

```
with Context("a") as A:                # path: [a]
    with Context("b") as B:            # B.path = "a:b"; path: [a,b]
        Foo("x")                       # registered in B; B.objects["component"]["x"] = Foo("x")
                                       # Foo._inferred_name = "x"
                                       # Foo.context_path = "a:b:x"
    # exit B: recompile B (compiles Foo("x")); path: [a]
# exit A: recompile A (compiles nothing new — B was already compiled); path: []
```

Subtlety: A's `recompile()` will iterate A's own `objects`, which does NOT
include B (Context is not registered in another Context — only via the
manager's `contexts` dict). B's objects are only compiled by B's own
`recompile`. **There is no recursive compile through nested contexts.**

### Exception during `with`

Python:

```python
def __exit__(self, exc_type, exc_val, exc_tb):
    self.recompile()
    gcm.step_to(self.__previous_path)
    self.__previous_path = None
```

No `if exc_type` check. Behavior:

- If user code in the body raised → `recompile()` runs anyway.
- If `recompile()` raises → `step_to(previous)` is skipped → manager is left
  with the entered path still on it → next operation will see stale state.
  **This is a real bug**; reproduce-as-is and fix in the Julia port.

### Idempotency of `Context(name)`

A second `Context("foo")` in the same scope:

1. `__new__` sees existing path "foo" and returns the existing instance.
2. `__init__` sees `_initialized` set and short-circuits.

So entering `with Context("foo") as f1:` then later `with Context("foo") as f2:`
yields `f1 is f2`. Two separate `with` blocks against the same context will
each recompile on exit — potentially compiling the same objects twice. Note
for the port: make `compile!` idempotent.

---

## Open questions / hazards

### 1. The duplicate-name check in `Context.registerObj` is buggy

`context.py:148` — `self.objects[_type].get(obj) is not None` keys the
existing-check by the object instance, not its name. The next line
`self.objects[_type][obj.name] = obj` keys by name. Two different objects
with the same name will silently overwrite. The Julia port should use
`name`-keyed lookup for both.

### 2. `step_to` always returns True despite docstring

`context_manager.py:75–91`. Document and either preserve (1:1) or fix in
port (preferred — return the result of `exists()`).

### 3. `register_context` stores by raw `path` argument, not joined string

`context_manager.py:197`: `self.__contexts[path] = context` — if `path` is a
list, the dict key is a list (unhashable in Python? no, a tuple is — a list
will actually `raise TypeError: unhashable type: 'list'`). In practice this
never fires because every caller passes a string from `append_path`. Port:
normalize to string at the boundary.

### 4. `recompile` does not handle objects without `compile`

`context.py:103` calls `obj.compile()` unconditionally if `_is_compilable`
is truthy. If the attribute is missing → AttributeError. Port: define
`compile!` as a no-op default, or check existence before calling.

### 5. Path restoration is not in a try/finally

`context.py:70–73`. If `recompile` throws, the manager's path is corrupted.
The Julia port should wrap in try/finally (see translation notes above) —
but this is a behavior change vs upstream. Flag in the design doc and ask
the user.

### 6. `compileObject` does class-introspection (`dir(obj)`)

`parser/utils.py:146` — walks every attribute via `dir`. Julia equivalent
is `fieldnames(T)` + `methodswith(T)`. The port of `compileObject` is the
parser agent's problem, but the Context module's `recompile` depends on
this working. Cross-module flag.

### 7. Cross-cuts with the Compartment / Component Phase A spec

The following lines in this module touch foreign types and must agree with
the other Phase A agent's spec:

- `context.py:14` — `from ngcsimlib._src.compartment.compartment import Compartment`
- `context.py:227–228` — `_connections[destination.root] = source`. The
  Compartment agent must define `root` as a stable string ID per compartment.
- `context.py:298–304` — `source.target` (when source is a Compartment) is a
  string; when source is a `BaseOp`, `source.to_json()` is called.
- `context.py:350` — `global_state_manager.get_compartment(connectionRoot)`.
  The compartment agent owns this registry.
- `contextAwareObjectMeta.py:62–65` — `if hasattr(obj, "compartments"): ...`
  Compartment agent's `_setup(name, path)` API.

The Julia port needs:

- `Compartment.root :: String`
- `Compartment.target :: Union{String, AbstractOp}`
- `setup!(comp, name, path)` callable, no-op default ok.
- A `GlobalStateManager` with `get_compartment(root) :: Compartment`.

### 8. Cross-cut with `BaseOp`

`context.py:7, 354` — `BaseOp.load_op(d)` reconstructs an op from JSON. The
Ops Phase A agent must expose this.

### 9. `modules_manager` (Python import-by-string) has no clean Julia analog

`context.py:6, 284, 329`. Python can `importlib.import_module("a.b.c")` and
get a callable class. Julia cannot do this generically — modules must be
loaded at compile time, and types are looked up by symbol. **The port must
replace `resolve_public_import` / `import_module` with an explicit type
registry:** a `Dict{String, Type}` populated by `@register_type` calls in
each component's module. This is a known idiom (cf. Flux, Lux, etc.).

### 10. Python MRO / descriptor protocol — anywhere it matters?

Only in `extract_name`:

```python
sig = inspect.signature(init)
bound = sig.bind_partial(None, *args, **kwargs)
```

This binds against `cls.__init__` (the most-derived MRO entry, after
unwrapping `_is_deprecated`). Subclasses with different `__init__`
signatures get their own. Julia has no MRO — multiple dispatch resolves at
the method level. **Recommended port:** require `name::AbstractString` as
either the first positional arg or a keyword arg in every aware type;
extract uniformly. No reflection.

### 11. `_priority` vs MRO interaction (none observed)

Priority is read from the *instance*, not the class. No MRO interaction.
Trait `priority(::AbstractContextAwareObject) = 0` plus per-type override
suffices.

### 12. `Context.load` runs inside its own `with` block

`context.py:319` — `with cls(metaData.get("path", module_name)) as ctx:`.
That means the loaded objects' `_inferred_name` paths are constructed
relative to `cls(metaData["path"])`. **But** `cls(path)` uses `path` as a
NAME, not a path — `__new__` then computes
`target = append_path(addition=path)`. So if `metaData["path"]` is
`"world:agent"`, the *loaded* context registers at
`current_path():"world:agent"` — possibly nested under whatever the caller's
path was. This is almost certainly a latent bug for nested loads; document
faithfully and recommend the Julia port treat the saved `path` as absolute
(reset `current_path` before load).

### 13. Two parallel APIs for path movement (`step` vs `step_to`)

`step` appends a single segment; `step_to` replaces the whole path. Both
mutate. The `register_context_local`/`__new__` path uses neither — it uses
`append_path` to *compute* a new string and registers under it without
moving the manager. The port should keep both move primitives but make sure
naming is unambiguous (`push_segment!` and `set_path!`).

### 14. Thread / Task safety — unresolved

No locks anywhere. Concurrent simulations in the same process will corrupt
the manager. The port must decide between: process-global manager (parity),
task-local manager (safest), or explicit-arg manager (purest). My
recommendation is the third for the public API, with a convenience
`GLOBAL_CONTEXT_MANAGER` for users who don't care.

### 15. `clear()` wipes contexts but not paths

`context_manager.py:40–45`: `self.__contexts.clear()` — but
`__current_path` is left intact. Calling `clear()` mid-`with` would orphan
the path. Document, and ensure the port either also clears the path or
documents that it doesn't.

---

## Summary for the main loop

The `context` module is a **path-keyed scope registry** that auto-captures
constructed objects into named buckets and recompiles them on scope exit.
Three pieces interlock:

1. `ContextManager` (`global_context_manager`) — process-global mutable
   path stack + global dict of all contexts ever made.
2. `Context` — get-or-create named scope; on enter, becomes current; on
   exit, recompiles its registered objects in priority-desc order.
3. `ContextAwareObjectMeta` — wraps every aware-object construction so the
   object's name pushes onto the path during `__init__` and the object
   auto-registers into the *enclosing* context.

For the Julia port:

- Replace metaclass with a `@context_aware` (and optional `@component` /
  `@process`) macro pair that:
  - declares the struct,
  - declares `context_type(::Type{T})`, `is_compilable`, `priority`,
    `name_of`, `compile!`,
  - emits an outer constructor that performs the
    push/init/setup-compartments/pop/register dance.
- Replace `with ctx: ...` with `with_context(ctx) do ... end`.
- Replace `importlib`-based load with an explicit type registry.
- Wrap the path-restoration in `try/finally`; decide whether to keep upstream's
  "recompile-on-exception" behavior — call this out for the user.
- Default to a global singleton manager, but parameterize the public API on
  `mgr::ContextManager` so tests can isolate.
