# 03 — Process subpackage spec

Source roots:
- `ngcsimlib/_src/process/__init__.py` — **empty (0 bytes)**, no re-exports.
- `ngcsimlib/_src/process/methodProcess.py` — `MethodProcess` (primary target of this spec).

Brief, but load-bearing supporting files (referenced extensively by `MethodProcess`; read in full to make this spec self-contained but **not** the primary spec target):
- `ngcsimlib/_src/process/baseProcess.py` — `BaseProcess`, the parent class.
- `ngcsimlib/_src/process/jointProcess.py` — `JointProcess`, sibling subclass.
- `ngcsimlib/_src/parser/utils.py` — `compilable`, `CompiledMethod`, `_bind`, `parse_method`, `_methodWrapper`, `compileObject`.

> **Scoping note for the synthesis pass.** The task prompt names `methodProcess.py` + `__init__.py` only. `BaseProcess` and `JointProcess` are in the same subpackage and `MethodProcess` cannot be specified in isolation (it inherits the `run`/`compile`/`pack_keywords`/`watch` surface from `BaseProcess`). They are covered here. `parser.utils` is summarised because it owns `compilable` and the AST→exec pipeline, but its full spec belongs to the parser-module audit.

---

## Purpose

A **Process** in ngcsimlib is **not a runtime loop and not a scheduler in the OS sense**. It is a **compile-time AST splicer** that produces a single pure Python function `f(ctx, loop_args) -> (ctx, watched)` from an ordered sequence of `@compilable` methods on Components.

Concretely:
- A `MethodProcess` records an ordered list of `(component_instance, method_name)` pairs (`baseProcess.py` and `methodProcess.py:33-50`).
- At context-close time the parser pipeline (`parser.utils.compileObject` → `parse_method`) walks each `@compilable` method, AST-transforms it into a `ctx, kwargs`-pure form, and stores the result on `method.compiled` as a `CompiledMethod` (`parser/utils.py:88-113`, `_bind` at `:53-71`).
- Process compilation (`BaseProcess.compile`, `baseProcess.py:150-209`) then **splices** the bodies of those compiled per-method ASTs into a fresh `FunctionDef(name=process.name, args=[ctx, loop_args])`, prepends an unpack of `loop_args` into the named keyword variables, appends a `return (ctx, watched_tuple)`, calls `ast.fix_missing_locations`, runs the standard library `compile(...)` + `exec(...)` two-step, and binds the resulting callable as `self.run.compiled` via `_bind`.
- `process.run(...)` is the user-facing entry; if compiled it calls `self.run.compiled(state, keywords)` and (optionally) writes the new state back to the global state manager (`baseProcess.py:111-144`).

So a Process is **a recipe + a one-shot AST-level linker + a pure callable**. The "runtime" is whatever loop the user writes around `process.run(...)`. There is no built-in scan/while/loop primitive in the Process layer.

**No JAX in this subpackage.** Verified by `grep -rn -E "(jax|jit|lax\.scan|lax\.while|vmap)" ngcsimlib/_src/process/` → 0 hits. Whatever JAX `jit` happens (if any) is applied below this layer (Component method bodies and/or whatever the user passes through `extra_globals` / `namespace` in `_bind`). This is the central JIT design question the Julia port must answer; see §JIT compilation.

---

## Public API

### `class MethodProcess(BaseProcess)` — `methodProcess.py:10-107`

Constructor & state:
- `__init__(self, name)` — `methodProcess.py:33-35`. Super-inits (`name`, `_keyword_order=[]`, `_watch_list=[]`) and adds `self.method_order: list[tuple[component, method_name_str]] = []`.

Chaining:
- `then(self, method) -> Self` — `methodProcess.py:38-47`. Appends `(method.__self__, method.__name__)` to `method_order`. `method` must be a **bound method** of a Component (so `__self__` and `__name__` resolve). Returns `self` for chaining.
- `__rshift__(self, method)` — `methodProcess.py:49-50`. Operator alias for `then`; enables `process >> comp.method1 >> comp.method2`.

AST splicing:
- `_parse(self) -> tuple[list[ast.stmt], dict[str, ast.AST], list[str], dict[str, Any]]` — `methodProcess.py:52-75`. The heart of MethodProcess. For each `(obj, method)`:
  1. Pulls the per-method `CompiledMethod` via `getattr(obj, method).compiled`.
  2. Skips non-`ast.Module` ASTs.
  3. Collects every arg name on the compiled FunctionDef **except `"ctx"`** into `key_set` — these become the process's keyword inputs.
  4. Takes `obj_ast.body[0].body[:-1]` — i.e. **the body of the function minus its trailing return** — and appends it to a flat `bodies` list.
  5. Merges `m.auxiliary_ast` into `extras`.
  Then assembles a merged `namespace` dict by concatenating each method's `compiled.namespace`.
  Returns `(bodies, extras, list(key_set), namespace)`.

Serialization:
- `to_json(self) -> dict` — `methodProcess.py:78-95`. Returns `{"args":[name], "kwargs":{}, "method_order":[{"name": obj.name, "method": method_str}, …], "watch_list":[c.root for c in self._watch_list]}`.
- `from_json(self, data) -> None` — `methodProcess.py:97-107`. Reads `method_order`, looks each component up by name via `global_context_manager.current_context.get_components(name)`, rebinds via `self.then(getattr(comp, method))`. Reads `watch_list`, resolves each compartment root via `global_state_manager.get_compartment(root)`, calls `self.watch(...)`.

### Inherited public API from `BaseProcess` — `baseProcess.py:18-209`

Class decoration order (top→bottom on the class statement, applied bottom→top): `@compilable @priority(-1) @process class BaseProcess(metaclass=ContextAwareObjectMeta)`.

- `__init__(self, name)` — `baseProcess.py:19-22`. Sets `self.name`, `self._keyword_order: list[str] = []`, `self._watch_list: list[Compartment] = []`.
- `watch_list` (property) — `baseProcess.py:24-26`. Returns `self._watch_list`.
- `view_compiled_method(self) -> str` — `baseProcess.py:28-35`. Returns `self.run.compiled.code` if compiled else `"Not Compiled"`.
- `watch(self, *compartments: Compartment) -> None` — `baseProcess.py:38-46`. Extends `_watch_list`.
- `get_keywords(self) -> list[str]` — `baseProcess.py:49-54`. Returns `self._keyword_order`. Order is set by `compile()` after `_parse()`.
- `pack_keywords(self, row_seed=None, **kwargs) -> list[Number]` — `baseProcess.py:56-86`. For each `key in self._keyword_order`, requires the key present in `kwargs`. If `kwargs[key]` is `callable`, calls it as `val(row_seed)` (errors if no seed). Otherwise appends value as-is. Returns the list **in `_keyword_order` order**.
- `pack_rows(self, length, seed_generator=None, **kwargs) -> list[list[Number]]` — `baseProcess.py:88-106`. Defaults `seed_generator` to identity `lambda x: x`. Returns `[pack_keywords(seed_generator(i), **kwargs) for i in range(length)]`.
- `is_compiled(self) -> bool` — `baseProcess.py:108-109`. `hasattr(self.run, "compiled")`.
- `run(self, state=None, keywords=None, update=True, row_seed=None, **kwargs)` — `baseProcess.py:111-144`. Entry point.
  - If not compiled: emits `warn(...)` (`baseProcess.py:142-144`) telling the user to close the context before calling.
  - If compiled:
    - Defaults `state` to `global_state_manager.state` (`baseProcess.py:133-134`).
    - Defaults `keywords` to `self.pack_keywords(row_seed=row_seed, **kwargs)` (`baseProcess.py:135-136`).
    - Calls `final_state, other = self.run.compiled(state, keywords)` (`baseProcess.py:137`).
    - If `update`: `global_state_manager.set_state(final_state)` (`baseProcess.py:138-139`).
    - Returns `(final_state, other)`.
- `_parse(self)` — `baseProcess.py:147-148`. Raises `NotImplemented` (note: the **constant**, not the **exception** — likely a latent bug in upstream but irrelevant to the port).
- `compile(self) -> None` — `baseProcess.py:150-209`. The AST emitter (full description in §JIT compilation below).

### `class JointProcess(BaseProcess)` — `jointProcess.py:11-80`

Same chain-build API as `MethodProcess`, but its units are **other Processes** rather than component methods.

- `__init__(self, name)` — `jointProcess.py:12-14`. Adds `self.process_order: list[BaseProcess] = []`.
- `then(self, process: BaseProcess) -> Self` — `jointProcess.py:16-22`. Pushes priority **below** the lowest sub-process priority (`if process._priority <= self._priority: self._priority = process._priority - 1`) — i.e. JointProcess always compiles after the latest sub-process. Appends to `process_order`. Returns self.
- `__rshift__(self, other)` — `jointProcess.py:23-24`. Alias for `then`.
- `_parse(self)` — `jointProcess.py:26-60`. For each sub-process: pulls `process.run.compiled` (note: a process's own compiled function), uses its AST. Skips the unpack stmt at position `0` only if the sub-process has any keywords (`start = 1 if has_keywords else 0`, `:41-44`), then strips the trailing return (`body[start:-1]`). Accumulates `key_set` via `process.get_keywords()` (union, deduped). Accumulates `joint_watch_list` from each sub-process plus `self._watch_list`, then **mutates** `self._watch_list = joint_watch_list` (`:53-57`). Returns `(bodies, extras, list(key_set), namespace)`.
- `to_json(self) -> dict` — `jointProcess.py:62-68`. `{"args":[name], "kwargs":{}, "process_order":[p.name for p in process_order], "watch_list":[c.root for c in _watch_list]}`.
- `from_json(self, data) -> None` — `jointProcess.py:70-80`. Resolves each process by name via `ctx.get_objects(*process_order, objectType=ContextObjectTypes.process)`, calls `self.then(proc)` for each. Watch list resolution identical to `MethodProcess.from_json`.

---

## Internal classes / functions

There are no module-private helpers inside `process/` itself. The privates are all in `parser/utils.py` and are public to the Process layer:

- `compilable(fn)` — `parser/utils.py:8-16`. Sets `fn._is_compilable = True`. Pure marker; no wrapping.
- `class CompiledMethod` — `parser/utils.py:19-51`. Carries `_fn` (the compiled callable), `_fn_ast` (the `ast.Module`), `_auxiliary_ast` (`dict[str, ast.AST]` of helper modules), `_namespace` (globals dict), `_extra_globals`. Properties: `auxiliary_ast`, `ast`, `extra_globals`, `namespace`, and `code` (`:45-48`) which `ast.unparse`s the auxiliary modules in **reverse insertion order** then the main fn, joined by `"\n\n"`. `__call__` forwards to `_fn`.
- `_bind(obj, method, ast_obj, namespace=None, auxiliary_ast=None, extra_globals=None)` — `parser/utils.py:53-71`. **The exec gateway.** Calls `compile(ast_obj, filename=f"{method.__name__}_compiled", mode='exec')`, defaults `namespace` to `method.__globals__.copy()` if `None`, runs `exec(code, namespace)`, picks the transformed function out of `namespace[ast_obj.body[0].name]`, wraps as a `CompiledMethod`, and uses `setattr(obj, method.__name__, _methodWrapper(method, compiled_method))` to **replace the unbound method attribute on the instance** with a wrapper that exposes both the original method (callable) and `.compiled` (the compiled artefact).
- `convert_kwargs(tree)` — `parser/utils.py:74-85`. Applies `KwargsTransformer` (separate file); rewrites `kwargs[KEY]` → `KEY`. Not used by Process directly.
- `parse_method(obj, method)` — `parser/utils.py:88-113`. Recursive entry that runs `_sub_parse`, gathers `additional_modules` (auxiliary helper ASTs from sub-methods), execs them into the namespace, then `_bind`s the top-level method.
- `_sub_parse(obj, method, sub=False)` — `parser/utils.py:116-133`. `textwrap.dedent(inspect.getsource(method))` → `ast.parse` → `ContextTransformer(obj, method, subMethod=sub).visit(tree)`. Recursively sub-parses any `needed_methods` (auxiliary methods discovered by the transformer).
- `compileObject(obj)` — `parser/utils.py:136-157`. Walks `dir(obj)`, finds attrs with `_is_compilable`. If the attr's type is `ContextAwareObjectMeta` (i.e. it's an inner context-aware object), recurses. Otherwise defers to a list and finally calls `parse_method(obj, attr)` on each. **This is the function that compiles all `@compilable` methods on a Component before the Process's own `compile()` runs.**
- `class _methodWrapper` — `parser/utils.py:161-170`. Holds `_method` (the original bound method) and `compiled` (the `CompiledMethod`). `__call__` forwards to `_method`. `__getattr__` falls through to `_method`. This is **what makes `comp.method(...)` still work normally while `comp.method.compiled` exposes the compiled version**.

---

## Data structures + invariants

### `MethodProcess` instance fields
| Field | Type | Owner | Lifecycle |
| --- | --- | --- | --- |
| `name` | `str` | self | Set at `__init__`; used as the generated `FunctionDef.name` (`baseProcess.py:176`). |
| `_keyword_order` | `list[str]` | self | Empty until `compile()` runs `_parse()` and assigns from `key_list` (`baseProcess.py:151-153`). After compile this is the authoritative order for `pack_keywords` and the `loop_args` tuple unpack. |
| `_watch_list` | `list[Compartment]` | self (extended via `watch()`) | Pure user-managed. Drives the `watched` tuple emitted at the end of the compiled function (`baseProcess.py:155-167`). |
| `method_order` | `list[tuple[Component, str]]` | self | Append-only via `then()`/`>>`. The `obj` is the **component instance**, not the class. The `method_name` is a string; `_parse()` re-resolves `getattr(obj, name).compiled` lazily, so compiles only have to have happened by the time `_parse` runs. |
| `run` | originally the inherited method; **replaced** by `_methodWrapper` after `compile()` | `_bind` (called from `compile()` at `baseProcess.py:206-209`) | After compile, `self.run` is callable AND has `.run.compiled` attr. |

### `JointProcess` adds:
| Field | Type | Lifecycle |
| --- | --- | --- |
| `process_order` | `list[BaseProcess]` | Append-only via `then()`. |
| `_priority` | `int` (inherited from `@priority(-1)` decorator) | Mutated in `then()` to be one below the lowest-priority sub-process. |

### Invariants
- **Compile-once, call-many.** `compile()` runs at context-close. After that, `run.compiled` exists and is the steady-state callable. There is no recompile-on-call path.
- **`ctx` arg is reserved.** `_parse` filters arg name `"ctx"` from the keyword set (`methodProcess.py:62-64`). Every compiled per-method body must take `ctx` as its first argument; the parser pipeline guarantees this via `ContextTransformer`.
- **Last statement of each per-method body is a `return` and is dropped.** `methodProcess.py:67` does `obj_ast.body[0].body[:-1]`. The process glues the remaining bodies sequentially. **Therefore the contract for `@compilable` methods is: last statement is always `return ctx` (or equivalent) so it can be stripped without losing computation.** The Julia port must reproduce this contract or rebuild it explicitly.
- **`loop_args` is a positional Python tuple in `_keyword_order` order.** `compile()` emits an unpack assignment `(k1, k2, …) = loop_args` at the top of the body (`baseProcess.py:190-201`) only if `len(_keyword_order) > 0`. Otherwise no unpack is emitted (and `JointProcess._parse` accordingly skips position 0 only when sub-process has keywords — `jointProcess.py:41-44`).
- **Watched compartments are looked up by `compartment.target`** as a `ctx[target]` `Subscript` in the AST emitted return (`baseProcess.py:158-167`). With zero watched compartments, the return tuple's second element is `ast.Constant(value=None)`.
- **State flow:** `run(state, keywords)` → compiled function reads/writes `ctx` (the state dict-like) and returns `(ctx, watched)`. If `update=True`, `BaseProcess.run` writes back to `global_state_manager.set_state(final_state)` (`baseProcess.py:138-139`).
- **`from_json` requires the context still containing the same-named components and the same-named compartments.** No fallback / error path beyond a quiet `if comp is not None and hasattr(comp, step['method'])` guard (`methodProcess.py:101-103`).

### How state is threaded
1. User constructs Process inside a `with Context(...) as ctx:` block (Context module; not in this spec's scope).
2. User chains: `process.then(component.method)` or `process >> component.method`.
3. Context close fires `compileObject(component)` (parser pipeline) → each `@compilable` method gains a `.compiled` attribute on the component.
4. Context close then fires `process.compile()` (priority `-1` ensures it runs last). `_parse()` reads `.compiled` off each component; `compile()` builds the splice and `_bind`s `self.run.compiled`.
5. User calls `process.run(state=initial_state, foo=val, bar=val)`. `pack_keywords` orders into a list `[foo_val, bar_val]`. The compiled function unpacks `loop_args`, walks the spliced bodies (each reads/writes `ctx[...]`), and returns `(ctx, watched_tuple)`.
6. If `update=True`, the global state manager mirrors the new ctx.

The **state object** (`ctx`) is **a single dict-like keyed by `compartment.target` strings**, threaded by reference through the compiled function. There are no per-statement state objects — every step mutates / reads the same `ctx`.

---

## JIT compilation

> **Headline finding:** the Process layer performs **no JAX-level JIT.** It performs **Python source-level AST splicing + `compile()` + `exec()`** to produce a single Python function whose body is the concatenation of the parsed-and-transformed bodies of the component methods. Any JAX `jit` / `lax.scan` / `vmap` is applied **outside** this subpackage. The Julia port's analogous primitive is therefore **not** `Reactant.@compile` per se — it is **AST construction**, and the compute backend is a separate concern.

Verified by `grep -rn -E "(jax|jit|lax\.scan|lax\.while|vmap)" ngcsimlib/_src/process/` → **zero hits**.

### What the `@compilable` mark actually does — `parser/utils.py:8-16`

```python
def compilable(fn):
    fn._is_compilable = True
    return fn
```

It is a **flag, not a wrapper**. `compileObject` later finds attributes with `_is_compilable` set and runs `parse_method` on them. That is the entire mechanism.

### What `compileObject` → `parse_method` does — `parser/utils.py:88-133`

1. `inspect.getsource(method)` → string of the Python source of the method.
2. `textwrap.dedent` + `ast.parse` → an `ast.Module` tree.
3. `ContextTransformer(obj, method, subMethod=sub).visit(tree)` — rewrites every reference to a context-aware compartment into `ctx[<target>]`-style subscripts, and tracks `needed_globals`, `needed_methods`, and `auxiliary_ast`. (Implementation in `parser/contextTransformer.py`, not in scope here.)
4. Recurse into `needed_methods` via `_sub_parse(..., sub=True)`.
5. `_bind`: `compile(tree, "...", "exec")` → `exec(code, namespace)` → pick the rebuilt function out of `namespace` → wrap in `CompiledMethod` → install on the instance as `_methodWrapper`.

The `namespace` passed to `exec` is `method.__globals__.copy()` by default, optionally extended by the caller. **Whatever names the original method referenced are available at compile time.** If the original method body called `jax.numpy.dot` etc., those calls survive into the compiled function untouched.

### What `BaseProcess.compile` does — `baseProcess.py:150-209`

1. `bodies, extras, key_list, namespace = self._parse()` — concrete impl in `MethodProcess` or `JointProcess`.
2. `self._keyword_order = key_list`.
3. Build the `watched` AST subexpression (a `Tuple` of `Subscript(ctx[target])` for each watched compartment, or `Constant(None)`).
4. Append `Return(Tuple(elts=[Name("ctx"), watched]))` to `bodies`.
5. Build a `FunctionDef(name=self.name, args=[ast.arg("ctx"), ast.arg("loop_args")], body=bodies, …)`.
6. If keywords exist, prepend an `Assign(targets=[Tuple([Name(k) for k in _keyword_order], Store)], value=Name("loop_args"))` — i.e. `(k1, k2, …) = loop_args`.
7. Wrap in `ast.Module(body=[FunctionDef], type_ignores=[])`.
8. `ast.fix_missing_locations(_compiled)`.
9. `_bind(self, self.run, _compiled, namespace=namespace, auxiliary_ast=extras)` — same exec gateway that compiles individual methods.

The result: `self.run` is replaced by a `_methodWrapper` whose `.compiled` is the pure function `f(ctx, loop_args) → (ctx, watched)`.

### Static vs dynamic args

Within the Process layer:
- **Static (compile-time):**
  - The method order (`method_order`).
  - The keyword name set (collected at `_parse` time).
  - Which compartments are watched.
  - The structure of every `@compilable` method body (frozen by `compileObject`).
- **Dynamic (per call):**
  - `ctx` (the state dict).
  - `loop_args` (the positional tuple of keyword values for this iteration).

There is no separate "static" vs "dynamic" mechanism comparable to `jax.jit(static_argnums=...)`. **Statics are baked into the AST at compile time. Dynamics are the two positional args of the compiled function.**

### `lax.scan` / `lax.while_loop` / `vmap` usage

None in this subpackage. Iteration over multiple "rows" of keywords is expressed at the **user-loop level** via `pack_rows` then a Python `for` loop calling `process.run(...)` per row. The Process layer does not own iteration.

### Tracing semantics

This is **AST-time compilation, not runtime tracing.** No abstract-value tracing happens. Every `ast.AST` decision is made before any data flows. The compiled function is a regular Python function once `exec`'d.

---

## External dependencies

Listed by module file:

### `process/methodProcess.py`
| Import | Usage | Julia equivalent |
| --- | --- | --- |
| `ngcsimlib._src.parser.utils.CompiledMethod` (`:1`) | Type hint on `m: CompiledMethod` in `_parse` (`:57`). | Local struct `CompiledMethod`. |
| `ngcsimlib._src.global_state.manager.global_state_manager` (`:2`) | Looked up in `from_json` (`:106`) to resolve compartments. | Whatever singleton/global the 02 state-manager spec defines. |
| `ngcsimlib._src.context.context_manager.global_context_manager` (`:3`) | `from_json` (`:99-101`) to fetch components from current context. | 01 context-manager singleton. |
| `ngcsimlib._src.process.baseProcess.BaseProcess` (`:4`) | Parent class. | Julia abstract type `AbstractProcess` with concrete subtypes. |
| `ast` (stdlib) (`:6`) | `isinstance(obj_ast, ast.Module)` (`:59`). | `Expr` / `Meta.parse` for source-level, or build IR directly. |
| `typing` (`:7`) | Type hints only. | Julia parametric types / no-op. |

### `process/baseProcess.py`
| Import | Usage | Julia equivalent |
| --- | --- | --- |
| `ContextAwareObjectMeta` (`:1`) | `metaclass=ContextAwareObjectMeta` on the class. | Julia trait or registration call in the type's outer constructor. |
| `process` decorator (`:2`) | `@process` on the class — registers the type with the context system. | Julia macro `@process` or explicit `register_process_type!(T)`. |
| `global_state_manager` (`:3`) | `run()` uses `.state` and `.set_state(...)`. | Module-level mutable struct + accessor fns. |
| `warn, error` (`:4`) | Logger calls. | `@warn`, `error()` builtins. |
| `priority(-1)` decorator (`:5`) | Sets `_priority` attr. | Julia macro `@priority(-1)` or constructor field. |
| `compilable`, `_bind as bind` (`:6`) | `@compilable` on class; `bind(self, self.run, _compiled, …)` at `:206-209`. | Marker trait + an `install_compiled!(::Process, ::CompiledMethod)` function. |
| `Compartment` (`:7`) | Type hint + `.target` / `.root` access. | The struct from the 02 state-manager spec. |
| `ast` (stdlib) (`:9`) | Heavy: `Constant`, `Tuple`, `Subscript`, `Name`, `Load`, `Store`, `Assign`, `Return`, `FunctionDef`, `arguments`, `arg`, `Module`, `fix_missing_locations`. | **In Julia: build `Expr(...)` trees directly, or build a typed IR.** No `fix_missing_locations` analogue needed — Julia's `Expr` does not carry source positions in the same way. |
| `typing`, `numbers` (`:11-12`) | Type hints. | n/a. |

### `process/jointProcess.py`
| Import | Usage | Julia equivalent |
| --- | --- | --- |
| `ast` (`:1`) | `isinstance(obj_ast, ast.Module)` (`:36`). | `Expr` head check. |
| `BaseProcess` (`:3`) | Parent. | abstract supertype. |
| `CompiledMethod` (`:4`) | Type hint. | local struct. |
| `global_context_manager` (`:5`) | `from_json` (`:73`). | 01 context manager. |
| `global_state_manager` (`:6`) | imported but not used in this file — vestigial. | n/a (skip). |
| `ContextObjectTypes` (`:7`) | `objectType=ContextObjectTypes.process` filter in `from_json` (`:73`). | A Julia `@enum` in the 01 context-manager spec. |

### `parser/utils.py` (summarised; not the main spec target)
| Import | Usage |
| --- | --- |
| `inspect.getsource` | Reads `.py` source from disk. **No clean Julia analogue.** See §Julia translation notes. |
| `ast`, `textwrap` | Parsing + dedent. |
| `ContextTransformer`, `KwargsTransformer` | The two `ast.NodeTransformer` subclasses that do the rewriting. |

### What is **not** imported anywhere in the Process subpackage
- `jax`, `jax.numpy`, `jax.lax`, `jax.jit`, `jax.vmap`, `jax.random`.
- `numpy`.
- Any tensor/array library.

This is significant: **the Process layer is array-library-agnostic.** Whatever array operations live in Component method bodies pass through unchanged. The Julia port can therefore implement the Process layer purely in terms of `Expr` / IR manipulation, deferring all Reactant/Enzyme concerns to the Component layer.

---

## Julia translation notes

### Naming

| Python | Julia |
| --- | --- |
| `BaseProcess` | `abstract type AbstractProcess end` |
| `MethodProcess` | `mutable struct MethodProcess <: AbstractProcess` |
| `JointProcess` | `mutable struct JointProcess <: AbstractProcess` |
| `CompiledMethod` | `struct CompiledMethod` |
| `_methodWrapper` | `mutable struct MethodWrapper{F}` or just store `compiled::Union{Nothing,CompiledMethod}` directly on the host struct (cleaner) |
| `@compilable` | `@compilable` macro that pushes the method onto a registry on the enclosing struct |
| `@priority(-1)` | field `priority::Int = -1` on the struct |
| `@process` | constructor call `register_process_type!(MethodProcess)` |
| `.then` / `__rshift__` | `then!(p, comp, :method)` and `Base.:>>(p, comp_method::Pair)` (e.g. `p >> (comp => :method)`) |

### Proposed core type definitions

```julia
# 03_process: process subpackage

abstract type AbstractProcess end

struct CompiledMethod
    fn::Function                       # the live callable (post Core.eval)
    fn_expr::Expr                      # the `Expr(:function, ...)` AST
    auxiliary_exprs::Dict{Symbol,Expr} # helper modules / sub-method ASTs
    namespace::Module                  # the module the fn was eval'd into
end

mutable struct MethodWrapper
    method::Function                     # original bound method (the "uncompiled" path)
    compiled::Union{Nothing,CompiledMethod}
end
(w::MethodWrapper)(args...; kwargs...) = w.method(args...; kwargs...)

mutable struct MethodProcess <: AbstractProcess
    name::Symbol
    priority::Int                            # default -1
    keyword_order::Vector{Symbol}            # set by compile!
    watch_list::Vector{Compartment}          # extended via watch!
    method_order::Vector{Tuple{Any,Symbol}}  # (component_instance, method_name)
    run::MethodWrapper                       # mutated by compile!
end

mutable struct JointProcess <: AbstractProcess
    name::Symbol
    priority::Int
    keyword_order::Vector{Symbol}
    watch_list::Vector{Compartment}
    process_order::Vector{AbstractProcess}
    run::MethodWrapper
end
```

### `Process → struct + step!` mapping

The task prompt suggests `step!(p::Process, state)`. **I recommend keeping the upstream name `run` (or `run!`)** because the semantics are one-iteration-of-spliced-bodies, which is exactly what the Python `run` does. There is no notion of a multi-step loop inside the process — the user's outer loop does that. So:

```julia
function run!(p::AbstractProcess; state=nothing, keywords=nothing,
              update::Bool=true, row_seed=nothing, kwargs...)
    is_compiled(p) || (@warn "Process $(p.name) not compiled"; return nothing)
    state === nothing      && (state = current_state(global_state_manager))
    keywords === nothing   && (keywords = pack_keywords(p; row_seed, kwargs...))
    new_state, watched = p.run.compiled.fn(state, keywords)
    update && set_state!(global_state_manager, new_state)
    return (new_state, watched)
end
```

### `@compilable` → Reactant: the actual design question

The literal upstream `@compilable` is a Python-level **AST-rewriting mark**. Reactant.jl's `@compile` / `@jit` is a **runtime tracing mark** that captures a function call's effect on `ConcreteRArray`s and lowers to MLIR. They are **not the same thing**.

There are two viable Julia strategies; pick at synthesis time:

1. **Mirror upstream literally.** Build the spliced Julia function as an `Expr`, `Core.eval` it into a generated module. Then **separately**, mark the resulting function for Reactant tracing at first `run!` call (`p.run.compiled.fn = @compile p.run.compiled.fn(state_proto, keywords_proto)`). Pro: 1:1 fidelity with upstream semantics, decoupled. Con: two compilation passes.

2. **Skip the AST splice, use a tuple of compiled callables.** Each `@compilable` method becomes a Julia function; `MethodProcess.run.compiled.fn` is the composition `(state, kws) -> foldl((s, f) -> f(s, kws), methods; init=state)`. Then mark `run.compiled.fn` for Reactant compilation. Pro: pure Julia, no `Expr` manipulation. Con: loses the ability to share variables across method bodies (upstream's splice means an assignment in method A's body is in scope for method B's body via the shared `ctx`; if `ctx` truly carries everything as upstream's design implies, then composition is equivalent and option 2 is strictly better).

**Recommendation:** read upstream `ContextTransformer` (out of scope here, but in `parser/contextTransformer.py`) to confirm whether spliced bodies share **only** `ctx` or also non-`ctx` locals. If only `ctx`, **option 2 is sufficient and much cleaner.** Flag this for the synthesis pass.

`@jit` vs `@compile` in Reactant.jl: Reactant.jl exposes both. `@compile` returns a compiled closure (call it later); `@jit` is the eager-compile-and-call form. For Process, **`@compile`** is the right primitive because we want a stable reusable handle. Verify against `Reactant.jl` README during scaffolding.

### Static vs dynamic args under Reactant

Reactant's tracing model uses **concrete types** of the inputs at trace time. So:
- `state` (the ctx dict) → must be a **typed, immutable-ish structure** for stable tracing. A `NamedTuple` of `ConcreteRArray`s is the canonical choice. **Not** a `Dict{Symbol,Any}` — that defeats tracing.
- `keywords` (the loop_args tuple) → a `Tuple` of `ConcreteRArray`s or scalars. The same shape on each call.

This is a real divergence from upstream: Python's `ctx` is a free dict. Julia's `ctx` should be a `@NamedTuple` (or generated struct). The Component / Compartment specs (01, 02) need to align here.

### Closures over state

Python upstream: state is threaded as the `ctx` positional arg; no closures. Julia port: same — keep state as an explicit arg, do not capture in closures. This is also what Reactant needs for clean tracing.

### `inspect.getsource` analogue

There is **no clean Julia equivalent**. Options:
- Use `CodeTracking.jl` (`@code_string`, but unreliable across method redefinitions).
- Capture the source at definition time via a macro: `@compilable function step(ctx, dt) … end` stores the `Expr` on the method registry, no source-from-disk roundtrip.

**Recommendation: the macro path.** It is cleaner, deterministic, and lets us drop the entire `parser/` subpackage's `inspect.getsource` machinery.

### AST manipulation

Julia's `Expr` is **easier** than Python's `ast` for this kind of rewriting:
- No `ast.fix_missing_locations` analogue needed.
- Splicing bodies is `quote ... end` interpolation: `:( $(body1...); $(body2...); return (ctx, $watched) )`.
- Building a `FunctionDef`: `Expr(:function, :(($ctx_sym, $loop_args_sym)), Expr(:block, body...))` then `Core.eval(mod, …)`.

### `_methodWrapper` analogue

A `MethodWrapper` mutable struct with `method::Function` and `compiled::Union{Nothing,CompiledMethod}`, with `(w::MethodWrapper)(args...; kwargs...) = w.method(args...; kwargs...)`. Make `w.compiled.fn` the Reactant-compiled version. `view_compiled_method(p)` returns `string(p.run.compiled.fn_expr)`.

### Serialization (`to_json` / `from_json`)

Use JSON3.jl or similar. Same schema as upstream. The `from_json` path requires a re-bind step: look up the component by name in the current context, push it onto `method_order`, then re-run `compile!`. **Do not try to serialize the compiled function** — recompile on load.

### Concrete trimmed prototype

```julia
function then!(p::MethodProcess, comp, method_name::Symbol)
    push!(p.method_order, (comp, method_name))
    return p
end
Base.:>>(p::MethodProcess, x::Pair) = then!(p, x.first, x.second)

function watch!(p::AbstractProcess, comps::Compartment...)
    append!(p.watch_list, comps)
    return p
end

function pack_keywords(p::AbstractProcess; row_seed=nothing, kwargs...)
    row = Any[]
    for k in p.keyword_order
        haskey(kwargs, k) || error("Key $k required for process $(p.name)")
        v = kwargs[k]
        if v isa Function
            row_seed === nothing && error("Generator for $k requires row_seed")
            push!(row, v(row_seed))
        else
            push!(row, v)
        end
    end
    return Tuple(row)
end

function compile!(p::MethodProcess)
    bodies, extras, key_list, namespace = _parse(p)
    p.keyword_order = key_list
    watched_expr = isempty(p.watch_list) ?
        :(nothing) :
        Expr(:tuple, (:(ctx[$(QuoteNode(c.target))]) for c in p.watch_list)...)
    full_body = Expr(:block,
        # unpack loop_args if any keywords
        (isempty(p.keyword_order) ? () :
            (Expr(:(=), Expr(:tuple, p.keyword_order...), :loop_args),))...,
        bodies...,
        :(return (ctx, $watched_expr))
    )
    fn_expr = Expr(:function, :((ctx, loop_args)), full_body)
    mod = Module(Symbol(p.name, "_compiled"))
    for (n, e) in namespace; Core.eval(mod, :(const $n = $e)); end
    fn = Core.eval(mod, fn_expr)
    p.run.compiled = CompiledMethod(fn, fn_expr, extras, mod)
    return p
end
```

(`_parse` in the same shape as upstream; details elided.)

---

## Open questions / hazards

### Cross-module overlaps the synthesis pass must resolve

1. **Compartment ↔ Process.** `_watch_list` holds `Compartment` instances and reads `.target` / `.root`. The Compartment type is owned by `02_*_spec.md` (state-manager / compartment module). **The Julia `Compartment` struct must expose `target::Symbol` and `root::Symbol` (or similar).** Flag for the synthesis pass: ensure both specs agree on these field names.
2. **Component ↔ Process.** `method_order` holds component instances and refers to their `@compilable` methods. The Component spec (likely 04 or 05) must:
   - Define `@compilable` as a marker macro.
   - Expose a `compileObject(comp)` analogue that compiles each `@compilable` method into a `CompiledMethod` attached to the component.
   - **Critical:** the `MethodProcess.compile!` step assumes each component method's compiled AST has the structure `function method(ctx, …kwargs): body; return ctx`. The Julia port must replicate that structure or splice differently.
3. **Context ↔ Process.** Context-close triggers `compileObject(component)` and then `process.compile()` (priority `-1`). The Context spec (01) must define a close-time hook and a priority ordering scheme.
4. **GlobalStateManager ↔ Process.** `run()` reads `global_state_manager.state` and writes `global_state_manager.set_state(...)`. The 02 spec must export these.

### Things I couldn't fully resolve from the source

1. **Does `_parse` correctly handle the case where two component methods use the same keyword name with different generators?** Upstream uses `key_set = set()` then `list(key_set)` — order is non-deterministic dict-iteration order. The Julia port should use an **insertion-ordered** structure (e.g. `OrderedSet`) for reproducibility. Flag.
2. **`_parse` `namespace` collision.** Line `methodProcess.py:71-73` merges every method's `compiled.namespace` into a single dict. If two methods define the same global name with different values, the **later one wins** (dict update order). Latent footgun. The Julia port should either:
   - Detect collisions and error, or
   - Use separate Modules per method and `using` them.
3. **`BaseProcess._parse` raises `NotImplemented` (the constant), not `NotImplementedError`.** Latent upstream bug: this would silently return `None` to the caller in many Python paths but raises `TypeError: cannot unpack non-iterable type` in `compile`. The Julia port should use a real abstract-method check: `_parse(::AbstractProcess) = error("Abstract method")`. Trivial fix.
4. **JointProcess imports `global_state_manager` but never uses it** (`jointProcess.py:6`). Vestigial. Drop in Julia.
5. **`from_json` is silently lossy** if a component or compartment is missing from the current context. No error / warn path. The Julia port should at least `@warn` on missing refs.
6. **`JointProcess._parse` mutates `self._watch_list`.** `jointProcess.py:53-57` overwrites `self._watch_list = joint_watch_list`. If `_parse` is called twice (e.g. user calls `compile()` twice for any reason), the watch list is duplicated. Probably benign because compile-once is the contract, but the Julia port should either rebuild from scratch each call or assert single-compile.
7. **Operator overload semantics for `>>`.** `MethodProcess >> bound_method` works because the right operand is a Python bound method with `.__self__` / `.__name__`. Julia has no equivalent of a bound method as a first-class value. The cleanest port is `p >> (comp => :method)`, but check what the WILLIAM/synthesis target expects ergonomically.

### Reactant.jl gotchas relative to JAX

1. **No `lax.scan` equivalent is used here, but the Component layer might.** Reactant has `Reactant.@trace_loop` / `@trace_for` (verify exact name) — has subtly different semantics (compile-time-known iteration count by default). Flag for the Component spec.
2. **No `vmap` here, but the Component layer might.** Reactant has `Reactant.@batch` (verify). Different broadcasting semantics from `jax.vmap`.
3. **No `jax.random` here, but `pack_keywords`'s generator pattern looks like it's used for per-row seeding** (`baseProcess.py:56-86`). In JAX, this would feed `jax.random.PRNGKey(seed)` into the method body. **In Julia, prefer threading an `AbstractRNG` through the state (`ctx`) explicitly** — Reactant doesn't have JAX's PRNG-as-pure-state idiom, and `Random.default_rng()` is global+mutating.
4. **`global_state_manager.state` as `ConcreteRArray`-bearing struct.** If `state` is a `NamedTuple` of arrays, Reactant tracing is happy. If it's a `Dict{Symbol,Any}`, it isn't. **Force the design to typed.**
5. **`ctx[target]` subscripts.** Upstream uses string-keyed subscripts. Julia port should use `Symbol`-keyed or property access (`ctx.target`) on a typed struct/NamedTuple. Mechanical rewrite at `_parse` time.

### Scope question to flag for the synthesis pass

`__init__.py` is **empty (0 bytes)**, so nothing from this subpackage is re-exported at package level. Any user-facing import in upstream must reach `ngcsimlib._src.process.methodProcess` directly OR go through `ngcsimlib/__init__.py` (out of scope here). The Julia port should make the choice once: are `MethodProcess` / `JointProcess` exported by `NGCSimLib`, or by a submodule? Recommend: yes, top-level export.

---

## Appendix: line-cited cross-reference table

| Symbol | File:line | Role |
| --- | --- | --- |
| `MethodProcess.__init__` | `methodProcess.py:33-35` | adds `method_order` |
| `MethodProcess.then` | `methodProcess.py:38-47` | append (component, method_name) |
| `MethodProcess.__rshift__` | `methodProcess.py:49-50` | alias for `then` |
| `MethodProcess._parse` | `methodProcess.py:52-75` | splice per-method ASTs |
| `MethodProcess.to_json` | `methodProcess.py:78-95` | serialize |
| `MethodProcess.from_json` | `methodProcess.py:97-107` | deserialize |
| `BaseProcess.__init__` | `baseProcess.py:19-22` | name + _keyword_order + _watch_list |
| `BaseProcess.watch_list` | `baseProcess.py:24-26` | property |
| `BaseProcess.view_compiled_method` | `baseProcess.py:28-35` | debug stringification |
| `BaseProcess.watch` | `baseProcess.py:38-46` | extend watch list |
| `BaseProcess.get_keywords` | `baseProcess.py:49-54` | read _keyword_order |
| `BaseProcess.pack_keywords` | `baseProcess.py:56-86` | order kwargs into list |
| `BaseProcess.pack_rows` | `baseProcess.py:88-106` | bulk pack |
| `BaseProcess.is_compiled` | `baseProcess.py:108-109` | check |
| `BaseProcess.run` | `baseProcess.py:111-144` | entry point |
| `BaseProcess._parse` | `baseProcess.py:147-148` | abstract |
| `BaseProcess.compile` | `baseProcess.py:150-209` | AST emit + bind |
| `JointProcess.__init__` | `jointProcess.py:12-14` | adds process_order |
| `JointProcess.then` | `jointProcess.py:16-22` | append + priority adjust |
| `JointProcess.__rshift__` | `jointProcess.py:23-24` | alias |
| `JointProcess._parse` | `jointProcess.py:26-60` | splice per-process ASTs |
| `JointProcess.to_json` | `jointProcess.py:62-68` | serialize |
| `JointProcess.from_json` | `jointProcess.py:70-80` | deserialize |
| `compilable` | `parser/utils.py:8-16` | marker decorator |
| `CompiledMethod` | `parser/utils.py:19-51` | compiled artefact carrier |
| `_bind` | `parser/utils.py:53-71` | compile + exec + install |
| `parse_method` | `parser/utils.py:88-113` | top-level method compiler |
| `_sub_parse` | `parser/utils.py:116-133` | recursive AST transform |
| `compileObject` | `parser/utils.py:136-157` | compile all @compilable on obj |
| `_methodWrapper` | `parser/utils.py:161-170` | callable + .compiled accessor |
