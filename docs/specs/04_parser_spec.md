# 04 — Parser (`ngcsimlib._src.parser`) — Julia Port Spec

Source root: `~/JuliaAGI/dev-zone/ngc-sim-lib/ngcsimlib/_src/parser/`
Files audited (every line read, no skim):
- `__init__.py` (122 B)
- `utils.py` (5 261 B)
- `contextTransformer.py` (7 819 B)
- `kwargsTransformer.py` (739 B)

Adjacent file inspected for behavioural correctness (Parser depends on these symbols at AST-rewrite time, not just runtime):
- `ngcsimlib/_src/compartment/compartment.py` (`Compartment._to_ast`, `.targeted`, `.fixed`, `.target`, `.root`, `.get_needed_keys`, `.set`, `.get`)
- `ngcsimlib/_src/context/contextAwareObjectMeta.py` (referenced by `isinstance(type(x), ContextAwareObjectMeta)` checks)

---

## Purpose

**Parser is a Python-AST transformer.** Not a config/text parser, not a runtime
evaluator. It is invoked at "compile" time on user-written `@compilable` methods
on `ContextAwareObject` subclasses (Components, Processes, sub-Components) and
**rewrites the method body** from "OO/stateful Python with `self.X` everywhere"
into a **pure function `f(ctx, **kwargs) -> ctx`** that JAX can trace / jit.

Header docstrings that establish this:
- `utils.py:9-14` — `compilable` decorator just tags `fn._is_compilable = True`.
- `utils.py:88-104` — `parse_method` docstring: *"Parses a method into a pure
  method that takes in just ctx and kwargs."*
- `contextTransformer.py:10-12` — *"This transformer works to transpile a
  compilable method into a pure method."*
- `kwargsTransformer.py:4-6` — *"This transformer replaces all instances of
  `kwargs[KEY]` with just `KEY` and tracks which ones it changes."*

The rewrite is a **whole-program transformation over a class instance**: every
method tagged `@compilable` on `obj` is parsed, sub-methods are inlined as
auxiliary top-level functions, sub-Components (other `ContextAwareObjectMeta`
instances) are compiled recursively, and the resulting set of pure-Python
functions is `compile()`-ed + `exec()`-ed into a fresh namespace and **rebound
onto the object via `_methodWrapper`** so `obj.method.compiled(...)` calls the
pure version while `obj.method(...)` still calls the original.

This is the Python equivalent of what in Julia would be done with a macro at
function-definition time. See the Julia translation section.

---

## Public API

All public re-exports come from `__init__.py:1-5`:

```python
from .utils import (
    compilable as compilable,
    parse_method as parse_method,
    compileObject as compileObject,
)
```

### `compilable(fn)` — `utils.py:8-16`
Decorator. Marks a method (or class) as compilable by setting
`fn._is_compilable = True`. Returns `fn` unchanged. The docstring mentions a
"priority" used to order compilation (higher = earlier, `-1` for Processes), but
**no priority is stored in this decorator** — priority handling is done by
the decorator usage convention elsewhere (the transformer at
`contextTransformer.py:46-47` strips a separate `priority(...)` decorator from
the decorator list, implying users stack `@priority(n)` above `@compilable`).
Hazard noted in *Open questions*.

### `parse_method(obj, method)` — `utils.py:88-113`
Parses one method into a pure function and attaches the compiled artefact to
`obj`.

Flow:
1. `_sub_parse(obj, method)` returns `(transformed_tree, additional_modules,
   extra_globals)`.
2. Build a namespace by copying `method.__globals__` and updating with
   `extra_globals`.
3. For each `(method_name, module)` in `additional_modules` (these are AST
   subtrees for inlined sub-methods / sub-Components), compile + `exec` into
   the shared namespace.
4. Call `_bind(obj, method, transformed, namespace, additional_modules,
   extra_globals)` which compiles the main tree, execs it, retrieves the new
   function by `ast_obj.body[0].name`, wraps it in `CompiledMethod`, and
   `setattr(obj, method.__name__, _methodWrapper(method, compiled_method))`.

**Side effect:** `obj.<method>` is replaced by a `_methodWrapper` instance.
Calling `obj.<method>(...)` still goes to the original bound method (via
`_methodWrapper.__call__` at `utils.py:166-167`), but
`obj.<method>.compiled(...)` calls the compiled pure version
(`CompiledMethod.__call__` at `utils.py:50-51`).

### `compileObject(obj)` — `utils.py:136-157`
Walks `dir(obj)`, finds every attribute marked `_is_compilable`, and:
- If the attribute's *type* is a `ContextAwareObjectMeta` (i.e. it's a
  sub-Component/Component-like nested object), **recurse**: `compileObject(attr)`.
- Otherwise queue it in `deferred_compile`.
- After traversal, call `parse_method(obj, attr)` for each queued method.

Two-phase ordering (recurse first, then compile own methods) matters because
`ContextTransformer.visit_Call` (see below) reads `subAttr.compiled.ast` from
already-compiled sub-Components.

### `CompiledMethod` — `utils.py:19-51` (class re-exported indirectly via the wrapper)
Stores the artefact bundle for one parsed method.

Constructor `__init__(self, fn, fn_ast, auxiliary_ast, namespace, extra_globals)`:
- `_fn` — the compiled, exec'd Python function object.
- `_fn_ast` — `ast.Module` containing the transformed `FunctionDef`.
- `_auxiliary_ast` — dict `{name: ast.Module}` of inlined sub-method ASTs (defaults to `{}`).
- `_namespace` — globals dict used by `exec`.
- `_extra_globals` — dict of synthesized globals (state values + free functions).

Properties:
- `ast` — `self._fn_ast`. `utils.py:32-34`.
- `auxiliary_ast` — `self._auxiliary_ast`. `utils.py:28-30`.
- `extra_globals` — `utils.py:36-38`.
- `namespace` — `utils.py:40-42`.
- `code` — human-readable source. Concats `ast.unparse` of auxiliaries in
  **reverse insertion order** then the main function (`utils.py:44-48`):
  ```python
  blocks = [ast.unparse(aast) for _, aast in list(self._auxiliary_ast.items())[::-1]]
  blocks.append(ast.unparse(self._fn_ast))
  return "\n\n".join(blocks)
  ```
- `__call__(*args, **kwargs)` → `self._fn(*args, **kwargs)`. `utils.py:50-51`.

### `_methodWrapper` — `utils.py:161-170`
Descriptor-like wrapper attached to `obj` in place of the original bound method.
- `__init__(self, bound_method, compiled)` — stores both.
- `__call__(self, *args, **kwargs)` → calls **original** `self._method(...)`.
- `__getattr__(self, attr)` → delegates to the underlying bound method.
- `self.compiled` → the `CompiledMethod` instance, so callers do
  `obj.foo.compiled(ctx, **kw)` to invoke the pure version.

---

## Internal classes / functions

### `_bind(obj, method, ast_obj, namespace=None, auxiliary_ast=None, extra_globals=None)` — `utils.py:53-71`
- `compile(ast_obj, filename=f"{method.__name__}_compiled", mode='exec')` — turns
  the AST into a Python code object. Wrapped in try/except that re-raises (no
  added context — see *Open questions*).
- Default namespace = `method.__globals__.copy()` if not passed.
- `exec(code, namespace)` populates the namespace with the new function.
- `transformed_func = namespace[ast_obj.body[0].name]` — pulls the freshly defined
  function out by its rewritten name (see name-rewriting at
  `contextTransformer.py:54`).
- Builds `CompiledMethod`, then
  `setattr(obj, method.__name__, _methodWrapper(method, compiled_method))`.

### `convert_kwargs(tree: ast.FunctionDef) -> Set[str]` — `utils.py:74-85`
Helper that wires up `KwargsTransformer`.
- `transformer = KwargsTransformer()`
- `transformed = transformer.visit(tree)`
- `ast.fix_missing_locations(transformed)`
- **Returns the set of transformed kwarg keys**, NOT the tree. Note: the
  transformer mutates in place / via the visit chain; the function returns
  `transformer.transformed_kwargs`. **This function appears unused inside the
  parser module itself** — `KwargsTransformer` is imported in `utils.py:4` but
  the only call site for `KwargsTransformer` would be `convert_kwargs`, and
  `convert_kwargs` is not called from `parse_method` / `_sub_parse` /
  `compileObject` / `_bind`. It is a public helper for external callers (e.g.
  the Process/Component runtime that builds a JIT signature from kwarg names).
  Flag in *Open questions*.

### `_sub_parse(obj, method, sub=False)` — `utils.py:116-133`
Recursive AST extractor for a single method.

1. `source = textwrap.dedent(inspect.getsource(method))` — pulls the live source
   of the method. **This means user methods must be importable from a real
   source file or REPL with source recoverable** (a generic `inspect.getsource`
   limitation). Hazard.
2. `tree = ast.parse(source)` — into a `Module` whose `.body[0]` is a `FunctionDef`.
3. Instantiate `ContextTransformer(obj, method, subMethod=sub)`.
4. `transformed = transformer.visit(tree)`.
5. `ast.fix_missing_locations(transformed)`.
6. Snapshot `transformer.needed_globals` → `extra_globals`.
7. Snapshot `transformer.auxiliary_ast` → `additional_modules`.
8. For each `(bound_name, method_name) in transformer.needed_methods.items()`:
   - Recurse: `_sub_parse(obj, getattr(obj, method_name), sub=True)`.
   - Merge results into `additional_modules` and `extra_globals`.
9. Return `(transformed, additional_modules, extra_globals)`.

The `sub=True` flag changes `ContextTransformer` behaviour:
- `visit_Return` returns `None` (drops the return) when **not** subMethod, and
  delegates to `generic_visit` when subMethod. Note this is **inverted from
  intuition** — see `contextTransformer.py:26-29` and *Open questions*.
- `visit_FunctionDef` only appends `return ctx` at the end of the body when
  **not** subMethod (`contextTransformer.py:57-58`).

### `ContextTransformer(ast.NodeTransformer)` — `contextTransformer.py:10-208`
The heart of the rewrite. Subclasses Python's `ast.NodeTransformer`. State
gathered during a visit:
- `self.obj` — the live Python object whose method is being parsed (used to
  evaluate `getattr` chains at parse time).
- `self.method` — the original method.
- `self.current_args` — set of positional arg names (minus `self`) of the
  function under transformation.
- `self.needed_keys` — set of compartment-state keys referenced (currently only
  unioned — see `visit_Attribute`).
- `self.subMethod` — bool, see above.
- `self.needed_methods` — `{rewritten_name: original_attr_name}` for `self.<m>(...)`
  calls that resolve to a bound method (recurse target).
- `self.needed_globals` — `{rewritten_name: value}` for `self.<x>` references
  that resolve to plain data or callable non-method objects.
- `self.auxiliary_ast` — `{method_id: ast.Module}` for inlined ASTs pulled from
  **already-compiled sub-Components** (see `visit_Call` `ContextAwareObjectMeta`
  branch).

Visitor methods (in source order):

- **`visit_Return(node)`** — `contextTransformer.py:26-29`. If `subMethod`,
  `generic_visit` it (so any nested transforms run). Otherwise return `None`,
  which deletes the return statement from the body. The transformer then
  manually appends `return ctx` at the end of the top-level FunctionDef.

- **`visit_FunctionDef(node)`** — `contextTransformer.py:31-66`.
  - Record `self.current_args` = positional args except `self`.
  - Rewrite `node.args` to `args=[arg if arg.arg != "self" else ast.arg(arg="ctx")
    for arg in node.args.args]`, clearing posonly/kwonly/varargs/kwargs.
    → Method signature `def f(self, a, b)` becomes `def NAME(ctx, a, b)`.
  - Strip decorators: drop `@priority(...)` (Call to Name `priority`), drop
    `@staticmethod` (Name), drop `@compilable` (Name). Keep all others.
    Lines 44-50.
  - Rewrite `node.name` to `obj.context_path.replace(":", "_") + "_" + node.name`
    (line 54). Example: a method `step` on a Component with context path
    `root:layer1` becomes `root_layer1_step`.
  - Recurse with `self.generic_visit(node)`.
  - If not `subMethod`: append `ast.Return(value=ast.Name(id='ctx', ctx=Load()))`
    (line 58). So top-level pure form is always `return ctx`.
  - Reset `self.current_args`.
  - For each `key in self.needed_keys`: if
    `global_state_manager.check_key(key)` is False, `warn(...)` (lines 62-64).
    **Note bug:** `self.needed_keys.union(...)` is called on line 77 but `union`
    returns a new set and the result is discarded — `self.needed_keys` is
    never actually populated. So this warn loop currently no-ops. See *Open
    questions*.

- **`visit_Attribute(node)`** — `contextTransformer.py:68-98`.
  Recurse first (`self.generic_visit`). Then if the form is `self.<attr>`
  (i.e. `node.value` is `ast.Name` with `id == "self"`):
  - Look up `stateVal = getattr(self.obj, node.attr)` **at parse time** —
    transformer reaches into the **live object** to decide which AST shape
    to emit. This is the central trick that makes Parser non-portable to a
    pure static AST tool.
  - **Case A — Compartment**: emit `stateVal._to_ast(node, 'ctx')` which
    produces `ctx["<compartment.target>"]` (see `compartment.py:125-132`:
    `ast.Subscript(value=ast.Name(id=ctx), slice=ast.Constant(value=self.target))`).
    Union `stateVal.get_needed_keys()` into `self.needed_keys` (buggy union,
    see above).
  - **Case B — sub-Component** (has `_is_compilable` and is a
    `ContextAwareObjectMeta` instance): return the original node unchanged
    (line 82). The actual rewrite for sub-Component method *calls* happens in
    `visit_Call` (different branch).
  - **Case C — callable** (free function or bound method): emit
    `ast.Name(id=f"{ctx_prefix}_{attr_name}")`. If `inspect.ismethod(stateVal)`,
    record in `self.needed_methods` (will be recursively `_sub_parse`-ed).
    Else record in `self.needed_globals` (injected into namespace as a free
    function reference).
  - **Case D — anything else (data)**: emit
    `ast.Name(id=f"{ctx_prefix}_{attr_name}")` and inject the *value itself*
    into `self.needed_globals`. So `self.threshold` (a float) becomes a global
    `root_layer1_threshold = 0.5`.

- **`visit_Call(node)`** — `contextTransformer.py:100-131`. Three nested branches:

  1. **Sub-Component method call** (line 104-123): if the call shape is
     `self.<subcomp>.<method>(...)`:
     - Verify `subcomp` is a `ContextAwareObjectMeta` instance — else return
       unchanged.
     - Grab `subAttr = getattr(subcomp, method_name)`. Must already have
       `.compiled` attached (else `error(...)` from logger — see *Open
       questions* for whether this raises).
     - Build `method_id = f"{subcomp.context_path.replace(':', '_')}_{method}"`.
     - `subAst = subAttr.compiled.ast` then **truncate** the last statement of
       the inlined function body: `subAst.body[0].body = subAst.body[0].body[:-1]`
       (line 116). This removes the trailing `return ctx` that was appended
       when the sub-method was originally compiled (since this call is being
       inlined into a parent that will return `ctx` itself).
     - Register the auxiliary AST under `method_id`, merge in the
       sub-method's own auxiliaries + globals.
     - Rewrite the call: `node.func = ast.Name(id=method_id)`,
       and **prepend `ctx` as the first arg**:
       `node.args = [ast.Name(id='ctx')] + node.args`.

  2. **`.get(...)` shorthand** (lines 125-126): if `node.func` is `<X>.get`,
     replace the entire call with `node.func.value` — i.e. `foo.get()` → `foo`.
     This works after Compartment AST rewriting: `self.x.get()` first gets
     `self.x` rewritten to `ctx["..."]`, so the call becomes `ctx["..."].get()`,
     which then collapses to `ctx["..."]`.

  3. **Local needed-method call** (lines 128-130): if `node.func` is a bare
     `Name` whose id is already in `self.needed_methods`, prepend `ctx` to
     `node.args`. Handles `self.helper(x)` (after `visit_Attribute` rewrote
     `self.helper` to `Name("ctx_helper")`) → `ctx_helper(ctx, x)`.

- **`visit_Expr(node)`** — `contextTransformer.py:133-144`. Catches a
  `.set(value)` statement and rewrites it into an assignment. Example:
  `self.x.set(5)` is first transformed (via `visit_Call` + `visit_Attribute`
  recursion) so `self.x` becomes `ctx["..."]`, then the outer Expr containing
  `ctx["..."].set(5)` is recognised here:
  - `target = call.func.value` (the `ctx[...]`).
  - Flip its context to `ast.Store()`.
  - Return `ast.Assign(targets=[target], value=call.args[0])`.
  - Net effect: `self.x.set(5)` → `ctx["..."] = 5`.

- **`_resolve_self_attr_chain_and_path(attr_node)`** — `contextTransformer.py:146-159`.
  Static helper. Walks an `Attribute` chain back to the base `Name`. Returns
  `(is_self: bool, chain: List[str] | None)`. Used by `visit_If` to detect
  `self.foo.targeted` patterns.

- **`visit_If(node)`** — `contextTransformer.py:161-208`. **Dead-code eliminates
  the branch at parse time.** Behaviour:
  1. Build `parent_map` so we can detect nested `Attribute`s.
  2. For each `Attribute` in the test expression that is **not nested inside
     another Attribute**, resolve its `self.X.Y...` chain.
     - If the chain ends with `targeted`, skip (allowed — see
       `compartment.py:64-66`).
     - Walk `getattr(obj, ...)` to resolve the live target.
     - If the resolved target is a `Compartment` and `target.fixed` is **False**,
       raise `RuntimeError(f"{obj.name}:{method.__name__}:[{target.root}],
       Conditionals can not be dependant on model state")`.
     - **NB:** `Compartment.fixed` is referenced here but I do **not see** a
       `fixed` attribute defined on the `Compartment` class in `compartment.py`.
       Flag as *Open question*.
  3. `compile(ast.Expression(node.test), "<ast>", "eval")` and **eval** the test
     **at parse time** with `{"self": self.obj}` as locals. If eval fails,
     `RuntimeError`.
  4. Pick `node.body` if truthy, else `node.orelse`.
  5. Visit each statement in the chosen branch; if visit returns a list, extend;
     else append. Returns a list of fix_missing_locations'd nodes.

  → **Conditionals over `self.X` (non-fixed compartments) are forbidden;
  conditionals over plain Python state are evaluated at compile time and the
  dead branch is dropped.** This is critical: it preserves traceability for
  JAX since the resulting function has no `if`-on-state.

### `KwargsTransformer(ast.NodeTransformer)` — `kwargsTransformer.py:3-25`
Tiny rewriter, separate from ContextTransformer. Visits `Subscript` nodes and
if the shape is `kwargs["KEY"]` (i.e. `Subscript(value=Name("kwargs"),
slice=Constant(str))`), rewrites it to `Name("KEY")` and records `"KEY"` in
`self.transformed_kwargs`. **There is a stray `print(ast.dump(node))` at line
21** — debug leftover. Flag in *Open questions*.

---

## Data structures + invariants

### Compiled artefact

```
CompiledMethod {
  _fn:             callable (compiled pure function)
  _fn_ast:         ast.Module containing one FunctionDef
                   - name = "<ctx_path>_<method_name>" (colons → underscores)
                   - args = [arg("ctx"), arg(<original positional args minus self>)]
                   - body ends in `return ctx`
  _auxiliary_ast:  dict[str, ast.Module]    (ordered, insertion order matters
                                             since CompiledMethod.code reverses
                                             it for printing)
  _namespace:      dict[str, Any]            (exec'd globals)
  _extra_globals:  dict[str, Any]            (synthesised globals: state values
                                             + free functions; subset of
                                             _namespace post-exec)
}
```

### `obj.<method>` after `parse_method` runs:
- Type changes from bound method → `_methodWrapper`.
- `obj.<method>(...)` still calls the original (unchanged behaviour).
- `obj.<method>.compiled` → `CompiledMethod`.
- `obj.<method>.compiled(ctx, **kwargs)` → executes the pure function.
- `obj.<method>.compiled.code` → human-readable rebuilt source.

### Invariants
1. Top-level pure function always **returns `ctx`** (line 58 in CT) — sub-methods
   do **not** append this (sub-methods rely on the caller's terminal return).
2. After parent inlines a sub-Component method, the sub-method's trailing
   `return ctx` statement is **stripped** (line 116 in CT). This means
   sub-method ASTs are *re-used in a mutated state* — if the same sub-method is
   referenced by two parents, the stripping happens once (in-place mutation
   `subAst.body[0].body = subAst.body[0].body[:-1]`), so re-inlining would
   strip again. **Hazard** — see *Open questions*.
3. Every `self.<attr>` reference is resolved at **parse time** against the live
   `obj`. So the object must be fully constructed and wired before
   `compileObject(obj)` is called.
4. `if`-conditions in compilable methods must be either over `self.<x>.targeted`
   or over **non-Compartment** state (i.e. constants knowable at compile time);
   the offending branch is deleted.
5. Decorator stripping is name-based — `@priority`, `@staticmethod`,
   `@compilable` (by string match) — any other decorator survives. Could break
   under `from .utils import compilable as compile_me`.

---

## Transformation behavior (the rewrite table)

| User wrote (inside `@compilable` method) | Becomes | Where |
|---|---|---|
| `def step(self, dt):` | `def root_layer1_step(ctx, dt):` | CT:34-42, 54 |
| `@compilable` decorator | (stripped) | CT:46-48 |
| `@priority(-1)` decorator | (stripped) | CT:46-47 |
| `@staticmethod` decorator | (stripped) | CT:48 |
| `self.x` where `x` is a `Compartment` | `ctx["root:layer1:x"]` | CT:70-79 + Compartment._to_ast |
| `self.x.get()` where x is Compartment | `ctx["root:layer1:x"]` (call collapses) | CT:125-126 |
| `self.x.set(value)` (as a statement) | `ctx["root:layer1:x"] = value` | CT:133-143 |
| `self.threshold` (plain data) | `root_layer1_threshold` (a synthesized global) | CT:93-96 |
| `self.helper(arg)` (free function attr) | `root_layer1_helper(arg)` (global) | CT:84-91 |
| `self.helper(arg)` (bound method attr) | `root_layer1_helper(ctx, arg)` + helper inlined recursively as auxiliary AST | CT:84-91, 128-130 + _sub_parse:127-131 |
| `self.subcomp.step(arg)` (subcomp is ContextAware) | `<subcomp_path>_step(ctx, arg)` + subcomp's AST grafted into auxiliary_ast (with trailing `return ctx` stripped) | CT:104-123 |
| `return X` at top level | (deleted; replaced by `return ctx` at function end) | CT:26-29, 57-58 |
| `if self.fixed_compartment.value == 0: A else: B` | A or B inlined; the `if` disappears | CT:161-208 |
| `if self.compartment.targeted:` | Permitted; live eval picks a branch | CT:176-177, 192-208 |
| `kwargs["lr"]` (KwargsTransformer only) | `lr` and "lr" added to `transformed_kwargs` set | kwargsTransformer:12-23 |

### When transformation runs
- **Not at decoration time.** `@compilable` only sets a flag.
- **At "compile" time**: when the user (or a framework wrapper) calls
  `compileObject(obj)`. This is **runtime** from Python's perspective but
  **once-per-object-lifetime** in practice.
- **Not at JIT time** (JAX): the produced pure function `obj.method.compiled`
  is what JAX subsequently jit-traces. Parser is the *preprocessor* that turns
  stateful methods into something JAX can handle. Confirmed by:
  - `Compartment.__jax_array__` (compartment.py:119-120) returns `.get()` —
    so the runtime `.get()` path still works for non-compiled execution.
  - The pure function only ever touches `ctx[...]`, never a `Compartment`
    object — that's why JAX tracing succeeds.

### Order of operations inside `compileObject`
1. Discover all compilable attributes of `obj` (via `dir`).
2. **Recurse into sub-Components** (other `ContextAwareObjectMeta` instances)
   FIRST — they must be compiled before the parent so that their
   `obj.<method>.compiled.ast` is available for inlining (CT:104-123 reads
   `subAttr.compiled.ast`).
3. Then compile `obj`'s own methods in `deferred_compile` order (which is
   `dir(obj)` order — alphabetical for Python ≥ 3.something — **not** the
   user-declared `priority`). Flag in *Open questions* — the `compilable`
   docstring implies priority-based ordering but the code doesn't sort by it.

---

## External dependencies

| Python module | Used in | Purpose | Julia equivalent |
|---|---|---|---|
| `ast` | all 4 files | parse / transform / unparse / compile Python source | Julia AST is `Expr`; built-in `Meta.parse`, `Base.remove_linenums!`, `MacroTools.@capture`, `MacroTools.postwalk` / `prewalk` / `replace`. |
| `inspect` | `utils.py:1`, `contextTransformer.py:2` | `inspect.getsource(method)`, `inspect.ismethod` | Macros run at parse time — source is **already** an `Expr`, no `getsource` needed. For runtime function reflection (rarely needed), use `methods(f)` / `which`. |
| `textwrap` | `utils.py:2` (`textwrap.dedent`) | strip leading indent from class-method source so it parses standalone | N/A — macros receive a flat `Expr` tree, no indentation. |
| `ngcsimlib._src.context.contextAwareObjectMeta` | `utils.py`, `contextTransformer.py` | `isinstance(type(x), ContextAwareObjectMeta)` test for "is this a (sub-)Component?" | Julia abstract type, e.g. `abstract type ContextAwareObject end` and `x isa ContextAwareObject`. |
| `ngcsimlib._src.global_state.manager.global_state_manager` | `contextTransformer.py:5` | `check_key(...)` to validate compartment keys exist | A `GlobalStateManager` struct (port from `02_global_state_spec.md`). |
| `ngcsimlib._src.logger` | `contextTransformer.py:6` | `warn`, `error` | Logging.jl `@warn`, `@error`. |
| `ngcsimlib._src.compartment.compartment.Compartment` | `contextTransformer.py:7` | runtime `isinstance` + `_to_ast` + `get_needed_keys` + `fixed` | Port from `03_compartment_spec.md` (or wherever Compartment lives). Need a `_to_ast`-equivalent method that emits the **Julia** `Expr` for a Compartment access in the rewritten function. |

No third-party deps. Pure stdlib + internal modules.

---

## Julia translation notes

### Verdict: this should be a Julia **macro** (or a small macro family), not a runtime AST transformer.

Python's design uses `inspect.getsource` + `ast.parse` + `compile` + `exec`
because Python does not expose the AST to user code at definition time. **Julia
does**: any `@macro` runs at lowering with the function's full `Expr` already in
hand. That eliminates almost all of `_sub_parse` and `_bind`.

But there's a subtlety: `ContextTransformer` resolves `self.<attr>` **against
the live object** (`getattr(self.obj, node.attr)`) to decide whether the
attribute is a Compartment, a sub-Component, a callable, or plain data. Julia
macros run at definition time, *before* the object exists. So the cleanest
Julia design has **two stages**:

1. **Definition-time macro `@compilable function ... end`** — records the
   raw method `Expr` on the type (or in a per-type registry), but does *not*
   rewrite it. Equivalent of `fn._is_compilable = True` in Python.

2. **Compile-time call `compile_object!(obj)`** — runs the actual rewrite,
   now that `obj` is fully constructed and we can introspect compartments /
   sub-components / etc. The rewrite is `MacroTools.postwalk` (or hand-rolled
   `Expr`-walking) over the stored raw `Expr`, with the same case analysis
   as `ContextTransformer.visit_Attribute` / `visit_Call` / `visit_Expr` /
   `visit_If` / `visit_Return` / `visit_FunctionDef`. Output is **new `Expr`
   trees**, which we `eval` into a per-object module so they become callable
   pure functions.

This is the most faithful 1:1 port: it preserves "rewrite happens after the
object is wired" semantics while using Julia AST tooling.

### Proposed Julia API (concrete)

```julia
# 1. Marker macro (sets metadata, does NOT rewrite).
"""
    @compilable function ... end
Tag a method as compilable. Records the raw Expr on the enclosing struct
for later rewriting via `compile_object!`.
"""
macro compilable(fdef)
    # Capture name, args, body. Store in a per-type WeakKeyDict or similar.
    # Return the original fdef unchanged so the un-compiled method still works.
end

# 2. Driver: rewrite all compilable methods on `obj` into pure functions.
"""
    compile_object!(obj)
Walks every compilable method on `obj` (and recursively on sub-components),
rewrites each into a pure `ctx::NamedTuple -> ctx` function, and attaches
the compiled form at `obj.<method>_compiled` (or a dedicated registry).
"""
function compile_object!(obj::ContextAwareObject)
    for sub in subcomponents(obj)
        compile_object!(sub)
    end
    for m in compilable_methods(obj)
        parse_method!(obj, m)
    end
end

# 3. Per-method rewrite (analogue of parse_method + _sub_parse + _bind).
function parse_method!(obj, method)
    raw_expr = compilable_source(typeof(obj), method)   # set by @compilable
    transformer = ContextTransformer(obj, method)
    new_expr, aux_exprs, extra_globals = transform!(transformer, raw_expr)
    # eval into a fresh module so symbols don't leak
    mod = Module()
    for (_, aux) in reverse(collect(aux_exprs)); Core.eval(mod, aux); end
    for (sym, val) in extra_globals; Core.eval(mod, :($sym = $val)); end
    Core.eval(mod, new_expr)
    fn = getfield(mod, Symbol(rewritten_name(obj, method)))
    register_compiled!(obj, method, CompiledMethod(fn, new_expr, aux_exprs,
                                                   mod, extra_globals))
end

# 4. AST transformer (mutable state akin to ContextTransformer).
mutable struct ContextTransformer
    obj
    method
    sub_method::Bool
    current_args::Set{Symbol}
    needed_keys::Set{String}
    needed_methods::Dict{Symbol,Symbol}
    needed_globals::Dict{Symbol,Any}
    auxiliary::OrderedDict{Symbol,Expr}
end

function transform!(t::ContextTransformer, ex::Expr)
    # Use MacroTools.postwalk + manual head-dispatch for Return / If / Call /
    # Assign / etc. (postwalk alone isn't enough — visit_If needs custom
    # pre-walk to dead-code-eliminate before its body is visited.)
end

# 5. CompiledMethod analogue.
struct CompiledMethod
    fn::Function
    fn_expr::Expr
    auxiliary::OrderedDict{Symbol,Expr}
    mod::Module
    extra_globals::Dict{Symbol,Any}
end
(c::CompiledMethod)(args...; kwargs...) = c.fn(args...; kwargs...)
Base.show(io::IO, c::CompiledMethod) = ...  # equivalent of .code
```

### Per-visitor translation table

| `ContextTransformer` method | Julia equivalent |
|---|---|
| `visit_FunctionDef` | When walking the top-level `Expr(:function, sig, body)`: rewrite the `sig` to replace `self` arg with `ctx`, append `ctx` as final body expression, mangle the function name to `Symbol("$(ctx_path)_$(name)")`. Strip decorator-equivalents (Julia's `@compilable`, any `@priority`). In Julia decorators are macros, so by the time we get the raw `Expr` the macro has already expanded — store the raw fdef *before* macros expand by using `@compilable` itself as a syntax-capturing macro. |
| `visit_Return` | `Expr(:return, x)` → if `sub_method`, recurse into x; else replace with nothing (delete). |
| `visit_Attribute` `self.x` | `Expr(:., :self, QuoteNode(:x))` — match against this and dispatch on `getfield(obj, :x)` type, just like Python. For Compartment → emit `Expr(:ref, :ctx, target_string)` (the Julia equivalent of `ctx[target]`). For data → emit synthesized global symbol + register in `needed_globals`. For callable bound method / free fn → same. **NB: Julia structs do not have getattr fallback; field access is `getfield(obj, :name)` and we must dispatch on type.** |
| `visit_Attribute` for sub-Component (`self.subcomp.method`) | Standard nested `Expr(:., Expr(:., :self, ...), ...)`. Look up `getfield(obj, :subcomp)`, check `<: ContextAwareObject`. |
| `visit_Call` `.set(v)` as a statement | Recognise `Expr(:call, Expr(:., target, QuoteNode(:set)), v)` inside `:block` / top-level — rewrite to `Expr(:(=), target, v)`. Subtle: must happen *after* the inner `self.x` rewrite turned `target` into `ctx["..."]`. |
| `visit_Call` `.get()` | `Expr(:call, Expr(:., target, QuoteNode(:get)))` → replace whole call with `target`. |
| `visit_Call` sub-Component method | `Expr(:call, Expr(:., Expr(:., :self, QuoteNode(:subcomp)), QuoteNode(:method)), args...)` → mangle and prepend `ctx`. |
| `visit_Expr` (statement wrapper) | Julia doesn't wrap top-level expressions in `:expr` nodes the way Python does — Julia blocks are `Expr(:block, stmts...)`. Handle `.set(...)` rewriting inside the block-walker rather than at an Expr wrapper. |
| `visit_If` (compile-time eval) | Most subtle. Detect `Expr(:if, cond, then, else)`. Walk `cond` looking for `Expr(:., :self, ...)` chains; resolve via `getfield`; if resolved object is a Compartment without `fixed` flag, error. Else `Core.eval` the condition with `:self => obj` substituted, pick the live branch, drop the other. (Beware closure capture — Julia closures capture variables, but here we are doing this at parse/compile time, evaluating a *constant expression* against `obj`, so it should be fine.) |
| `visit_FunctionDef` decorator stripping | In Julia, macros expand top-down. If we want to strip `@priority(...)` from a `@compilable` fdef, we need either: (a) `@compilable` runs first (innermost) and stores the raw fdef before `@priority` sees it; or (b) `@priority` collaborates by storing metadata and forwarding the raw fdef. Easiest: define `@compilable` so it's used as the *outermost* macro: `@compilable @priority(-1) function ... end`. Then `@compilable` receives the inner macro call unexpanded and can strip / inspect. |

### `KwargsTransformer` → Julia

Trivial. Walk `Expr`, replace `:(kwargs[KEY])` with `:KEY` and record `KEY`.

```julia
function convert_kwargs!(ex::Expr)
    keys = Set{Symbol}()
    rewritten = MacroTools.postwalk(ex) do node
        if MacroTools.@capture(node, kwargs[s_String])
            push!(keys, Symbol(s))
            return Expr(:Symbol(s))   # actually: just `Symbol(s)` as the identifier
        end
        return node
    end
    return rewritten, keys
end
```

(Note: drop the stray `println(ast.dump(node))` debug from the Python — see
Open questions.)

### Where `ctx` lives

Python's `ctx` is the global-state dict at parse-rewritten function call time
(`ctx["root:layer1:x"]`). In Julia the natural shape is a `Dict{String,Any}`,
or — for performance — a `NamedTuple` whose field names are pre-mangled
context paths (colons → underscores). Pick after we know how the global-state
manager (`02_global_state_spec.md`) is implemented; this spec doesn't dictate.
For Reactant/Enzyme tracing, **NamedTuple is strongly preferred** since it
gives static field types and lets the AD pipeline see fixed structure.

### Reactant.jl / Enzyme.jl interaction

- Parser produces a function with shape `ctx -> ctx`. This is exactly the
  shape Reactant likes to trace (`@compile`) and Enzyme likes to differentiate.
- All branches over state are pre-resolved at parse time (`visit_If`), so the
  traced function has no data-dependent control flow over Compartments — JAX
  parity preserved.
- No `Compartment` objects ever appear in the rewritten body — only
  `ctx["..."]` accesses. So Reactant tracing sees plain array slot reads/writes,
  which is what we want.

---

## Open questions / hazards

1. **`self.needed_keys.union(...)` is discarded** (`contextTransformer.py:77`).
   `set.union(...)` returns a new set in Python — should be
   `self.needed_keys |= stateVal.get_needed_keys()` or `.update(...)`. The
   subsequent warn loop (lines 62-64) is therefore a no-op in practice. Port
   should **fix** this in Julia (use a mutating `union!`) and verify against
   tests.

2. **`Compartment.fixed` attribute** is referenced at
   `contextTransformer.py:186` but I do not find `.fixed` defined in
   `compartment.py`. Either it's added by a metaclass (`CompartmentMeta`),
   set dynamically elsewhere, or this branch is dead in current code.
   Investigate during port — read `compartmentMeta.py`.

3. **`@priority` decorator semantics undocumented**: the `compilable`
   docstring (`utils.py:11-13`) says higher priority is compiled earlier, but
   `compileObject` iterates `dir(obj)` which gives **alphabetical** order, not
   priority order. Either:
   - The `priority` stack is processed elsewhere (e.g. on the runtime side
     when Processes schedule compilable methods), or
   - It's a latent bug / documentation drift.
   Confirm before porting; if priority *does* matter, sort `deferred_compile`
   by it in the Julia version.

4. **Sub-method AST mutation hazard**
   (`contextTransformer.py:116`):
   `subAst.body[0].body = subAst.body[0].body[:-1]` mutates the inlined
   sub-method's AST **in place**. If a single sub-method is inlined into two
   different parents, the second inline strips again — possibly removing a
   real statement. Port should `deepcopy` the sub-AST before stripping.
   Verify with a unit test (sub-Component method called by two parents).

5. **Stray `print(ast.dump(node))`** in `kwargsTransformer.py:21`. Debug
   leftover. Do not port.

6. **`error(...)` from logger** at `contextTransformer.py:112` — does this
   raise or just log? Need to read `ngcsimlib._src.logger`. If it only logs,
   the transformer continues with an undefined `method_id` chain — likely a
   real bug. Decide port behaviour (probably raise).

7. **`visit_Return` polarity feels inverted.** When `subMethod` is True, the
   transformer recurses; when False, it deletes. Combined with the manual
   `return ctx` append at line 58 (also only when not subMethod), the logic
   is: "top-level functions: drop user returns, add `return ctx`; sub-methods:
   keep user returns (recursed)." But sub-methods are *inlined* and then their
   trailing statement stripped (line 116), so even kept returns get nuked.
   Net behaviour seems correct, but the polarity reads awkwardly. Document
   clearly in the port.

8. **Decorator stripping is name-based string match** (CT:46-50): `priority`,
   `staticmethod`, `compilable`. If a user does
   `from .utils import compilable as compile_it`, the `@compile_it` decorator
   would be kept and break `compile()`. Julia macros have similar fragility —
   port should match against fully qualified `:(ngcsimlib.compilable)` if
   possible, or use a metadata-table lookup rather than string match.

9. **`convert_kwargs` is dead inside the parser package.** It's exported via
   `utils.py` symbols but not called by `parse_method` / `_sub_parse` /
   `compileObject`. Likely called by a Process / runtime layer that builds the
   JIT-signature. Confirm where during port; the Julia equivalent goes in
   whichever module owns Process compilation.

10. **`inspect.getsource(method)` brittleness.** Requires the original source
    file on disk and uncached source. Methods defined dynamically (e.g. via
    `exec`) cannot be re-parsed. Julia macros sidestep this entirely — the
    `Expr` is captured at parse time and stored — so this hazard goes away
    in the port.

11. **Compartment / Component / Context / Process overlap.** Parser reaches
    into:
    - `Compartment._to_ast`, `.get_needed_keys`, `.target`, `.fixed`,
      `.targeted` — port of Parser **depends** on the Compartment port
      exposing an `_to_expr(ctx_sym)` method that returns the Julia `Expr`
      for a compartment access (analogue of Python's `ast.Subscript`).
    - `ContextAwareObjectMeta` (used in `isinstance(type(x), ...)` tests) —
      port needs a Julia abstract type or trait (`is_context_aware(::Type)`)
      with the same dispatch semantics. Components, Processes, sub-Components
      all share this trait.
    - `obj.context_path` (CT:54, 85, 93, 114) — provided by Context port.
      Format `"a:b:c"` is colon-separated and mangled to underscores for use
      as a Julia identifier.
    - `obj.name`, `obj.method.__name__` — used in error messages and aux-AST
      keying.
    - `global_state_manager.check_key(...)` — provided by GlobalState port.
    Flag explicit cross-spec contract: **Compartment must expose an
    `_to_expr(node_ctx, ctx_sym::Symbol)` method returning an `Expr` of shape
    `Expr(:ref, ctx_sym, target_str)`**, mirroring Python's `_to_ast`.

12. **Order of `auxiliary_ast` insertion vs `code` reversal** (`utils.py:46`).
    The `code` property reverses the insertion order before unparsing. So the
    "top of file" ends up being the most-recently-inserted auxiliary. Why
    reverse? Probably because `_sub_parse` inserts depth-first and the deepest
    leaves must be defined first for `exec` ordering. But `exec` happens
    *separately* per auxiliary in `parse_method` (`utils.py:108-110`) and
    *not* by unparsing `code`. So `code` is for human readability only and
    the reversal is presentational. Port should preserve this for parity but
    flag that it doesn't affect execution.

13. **Closure capture differences.** Python's `exec(code, namespace)` injects
    everything into one shared namespace, so the rewritten function sees
    state values as global names. In Julia, evaluating an `Expr` inside an
    anonymous `Module()` and pulling the function out gives the same shape,
    but **constant folding** by Julia's compiler may treat synthesized
    globals as `const`-able only if we declare them so. For performance with
    Reactant, prefer to **bake constants into the `Expr`** instead of routing
    through module-level bindings — i.e. emit `0.5` directly instead of
    `Expr(:Symbol("root_layer1_threshold"))` when the value is a primitive.
    This is an optimisation, not required for correctness.

14. **No "priority" sort at compile order.** See (3). If the Julia port wants
    matching priority semantics, add `sort!(deferred_compile, by=priority,
    rev=true)` before iterating.

15. **No tests included in this directory.** I did not look outside
    `_src/parser/`. Port should pull whichever upstream tests cover
    `compileObject` + `parse_method` (likely under `tests/parser/` or via
    Component/Process tests) as the acceptance suite.

---

## Cross-spec contracts (must match)

For Parser to port cleanly, the sibling Julia ports must provide:

- **Compartment**: `_to_expr(ref_node, ctx_sym::Symbol)::Expr`, `target::String`,
  `fixed::Bool`, `targeted::Bool`, `get_needed_keys()::Set{String}`, `root::String`.
- **Context / Component**: `ContextAwareObject` abstract type (or `is_context_aware`
  trait); `context_path::String` on instances; recursive iteration over
  sub-Components.
- **GlobalState**: `check_key(key)::Bool`.
- **Logger**: `@warn`, `@error`; decision on whether `@error` raises.
- **`@compilable` macro**: registers raw `Expr` per-method per-type, returns
  fdef unchanged so non-compiled call still works.

Once those land, Parser is a ~200-300 LOC Julia file plus tests.
