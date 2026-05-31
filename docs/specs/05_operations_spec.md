# Operations Module — Julia Port Spec (Phase A)

**Source tree**: `ngcsimlib/_src/operations/`
**Files**:
- `__init__.py` (3 lines, re‑exports only)
- `BaseOp.py` (94 lines)
- `Summation.py` (19 lines)
- `Product.py` (22 lines)

**Cross‑references read for context** (NOT part of the module but the contract
relies on them):
- `ngcsimlib/_src/compartment/compartmentMeta.py` (`CompartmentMeta` metaclass)
- `ngcsimlib/_src/compartment/compartment.py` (`Compartment` — peer node type)

---

## Purpose

An **Op** is a *deferred, inline arithmetic combinator* over one-or-more
`Compartment` (or nested `BaseOp`) operands. From `BaseOp.py:8-12`:

> "The base class for all operations. These allow for inline transformations of
> values as they are passed between components. They are all set up as
> pseudo-compartments but do not actually have a value in the global state."

Properties from the source:

1. **Pseudo‑compartment, no own storage.** Ops use the same `CompartmentMeta`
   metaclass as `Compartment` (`BaseOp.py:7`) so they share dunder arithmetic
   and can be wired the same way (`>>`, see `BaseOp.py:85-87`), but they do
   not call `gState.add_compartment(self)` and they have no `name` / `root`
   key. They are *not* keys in the global state dict.
2. **Stateless value, stateful structure.** An Op stores a tuple of operand
   references (`self._comps`, `BaseOp.py:14`) plus a single `ast` operator
   token (`self.astOp`, `BaseOp.py:15`). It owns no numeric value; it computes
   it on demand by calling `.get()` on each operand and reducing them.
3. **A node in a tiny expression dataflow graph.** Operands may themselves be
   `BaseOp` instances (`BaseOp.py:46`, `BaseOp.py:58-60`, `BaseOp.py:81-82`)
   so an Op forms an *expression tree* whose leaves are `Compartment`s.
4. **Compilable.** An Op can lower itself to a Python `ast.BinOp` subtree
   (`BaseOp.py:30-51`) so the framework's process compiler can splice the
   whole expression tree into a generated function body. Each concrete Op
   contributes one `ast.<operator>()` token (`Summation.py:13` =
   `ast.Add()`; `Product.py:13` = `ast.Mult()`).
5. **Serializable.** `to_json` / `from_json` (`BaseOp.py:53-63`, `76-82`)
   round‑trip Ops by recording the module path of the concrete class plus
   either the `root` key of each leaf compartment or a nested op dict for
   inner ops.

Net: an Op is **(a)** a value provider (duck‑typed against `Compartment` via
`.get()` / `._get_value()` / `_to_ast()` / `get_needed_keys()`), **(b)** a
constructor of an AST fragment for the JIT compiler, and **(c)** a
JSON‑serializable record.

---

## Public API

### Package surface — `operations/__init__.py:1-3`

```python
from .BaseOp import BaseOp
from .Summation import Summation
from .Product import Product
```

Exactly three names: `BaseOp`, `Summation`, `Product`.

### `BaseOp` (`BaseOp.py:7-94`)

`class BaseOp(metaclass=CompartmentMeta)` — abstract base for all ops.

| Member | Signature | File:line | Behavior |
|---|---|---|---|
| `__init__` | `__init__(self, *comps)` | 13-15 | Stores operands in `self._comps = list(comps)`. Sets `self.astOp = None` (subclass MUST override). |
| `get` | `get(self) -> Any` | 17-21 | Public entry point. Calls `self._get_value()`. |
| `_get_value` | `_get_value(self) -> Any` | 23-28 | **Required override.** Returns the computed result. Default returns `NotImplemented` (sentinel — *not* raised). |
| `_to_ast` | `_to_ast(self, node, ctx) -> ast.AST` | 30-51 | Emits an `ast.BinOp` subtree using `self.astOp` as the operator. See "AST lowering" below. |
| `to_json` | `to_json(self) -> dict` | 53-63 | Returns `{'modulePath': <import_path>, 'compartments': [...]}`. Nested ops recurse; leaf compartments contribute `comp.root` (a string). |
| `get_needed_keys` | `get_needed_keys(self) -> set[str]` | 66-73 | Union of `get_needed_keys()` across operands. **Note: bug — uses `keys.union(...)` non-mutatingly; see "Hazards" §.** |
| `from_json` | `from_json(self, data)` | 76-82 | Reverse of `to_json`. String entries fetched via `gsm.get_compartment(path)`; dict entries reloaded via `BaseOp.load_op(...)`. |
| `__rshift__` | `__rshift__(self, other)` | 85-87 | Wire operator: if `other` is a `Compartment` (detected via `CompartmentMeta` in MRO), defers to `other.__rrshift__(self)` which sets `other.target = self`. |
| `load_op` *(static)* | `load_op(op) -> BaseOp` | 89-93 | Resolves `op['modulePath']` via `modManager.import_module`, instantiates the class with no args, calls `from_json`. |

#### Instance fields

| Field | Set at | Type | Notes |
|---|---|---|---|
| `_comps` | `__init__` (line 14) | `list[Compartment \| BaseOp]` | Operand list. Subclasses do **not** override `__init__` storage — they only extend it (e.g. `Summation.__init__` calls `super().__init__(*compartments)`). |
| `astOp` | `__init__` (line 15) → set by subclass | `ast.operator` instance | Used by `_to_ast` as the binary operator. Subclasses must set this before any compilation occurs. |

### `Summation` (`Summation.py:5-16`)

```python
class Summation(BaseOp):
    def __init__(self, *compartments):
        super().__init__(*compartments)
        self.astOp = ast.Add()

    def _get_value(self):
        return sum(self._comps)
```

| Member | File:line | Behavior |
|---|---|---|
| `__init__` | 11-13 | Passes operands to `BaseOp.__init__`; sets `self.astOp = ast.Add()`. |
| `_get_value` | 15-16 | Returns `sum(self._comps)` — relies on `Compartment.__add__` (installed by `CompartmentMeta`) to recursively unwrap each operand via `_unwrap` (see `compartmentMeta.py:5-8`). The `start=0` of Python's `sum` plus `__radd__` from the metaclass make this work. |

### `Product` (`Product.py:5-19`)

```python
class Product(BaseOp):
    def __init__(self, *compartments):
        super().__init__(*compartments)
        self.astOp = ast.Mult()

    def _get_value(self):
        x = 1
        for comp in self._comps:
            x *= comp.get()
        return x
```

| Member | File:line | Behavior |
|---|---|---|
| `__init__` | 11-13 | Passes operands to `BaseOp.__init__`; sets `self.astOp = ast.Mult()`. |
| `_get_value` | 15-19 | Manual fold: starts with scalar `1`, multiplies in `comp.get()` for each operand. **Asymmetric with `Summation`**: `Summation` uses `sum(self._comps)` (no explicit `.get()`), `Product` uses `comp.get()`. See "Hazards" §. |

---

## BaseOp interface (contract for subclasses)

### Required overrides

A concrete Op subclass must:

1. **Set `self.astOp`** to an instance of an `ast.operator` (e.g. `ast.Add()`,
   `ast.Mult()`, `ast.Sub()`, ...) inside `__init__`. `BaseOp._to_ast` uses
   this verbatim at line 49. If left as `None`, AST lowering will crash.
2. **Override `_get_value(self)`** to return the reduced/computed value. The
   default (line 28) returns `NotImplemented` which propagates silently and
   poisons downstream computations.

### Optional overrides

Subclasses *should not* override:
- `__init__` storage semantics (must call `super().__init__(*compartments)`).
- `_to_ast` (the default left-fold over `_comps` with `astOp` handles all
  binary-associative cases).
- `to_json` / `from_json` / `load_op` (handle every subclass uniformly via
  `modManager.resolve_public_import(self)`).
- `get`, `get_needed_keys`, `__rshift__`.

Subclasses *may* override `_to_ast` if the operation is non‑BinOp shaped (e.g.
a unary op or a function call like `jax.numpy.sum`). Neither shipped Op does.

### Method signatures and data flow

```
                       op = Summation(c1, c2, c3)
                       |
                       v
              op.get()
              |
              v
   BaseOp.get -> self._get_value()                         # value path
                 = sum(self._comps)
                 -> CompartmentMeta.__add__(c1, c2)
                    -> _unwrap(c1) + _unwrap(c2)           # via gState.from_global_key
                 -> ... fold ...

              op._to_ast(node, ctx)                        # compile path
              |
              v
   if len(_comps)==1: -> _comps[0]._to_ast(node, ctx)
   else: left-fold ast.BinOp(left, op=astOp, right)

              op.to_json()                                 # serialize path
              -> {'modulePath': '...Summation',
                  'compartments': [<leaf.root | inner.to_json()>, ...]}
```

### AST lowering — `BaseOp._to_ast` (`BaseOp.py:30-51`) in detail

```python
def _to_ast(self, node, ctx):
    if len(self._comps) == 1:
        return self._comps[0]._to_ast(node, ctx)         # passthrough
    inners = [comp._to_ast(node, ctx) for comp in self._comps]
    left = inners[0]
    for inner in inners[1:]:
        left = ast.BinOp(left=left, op=self.astOp, right=inner)
    return left
```

Key facts:
- **Left‑associative** linear fold; no parenthesization choice issues since
  `+` and `*` are associative.
- The `node` argument is the original AST node being replaced (used by
  `Compartment._to_ast` at `compartment.py:130` to copy `node.ctx`). Ops do
  not consume `node` themselves; they only forward it.
- `ctx` is the **name** (a `str`) of the global state dict in the generated
  function scope. `Compartment._to_ast` lowers a leaf to
  `ast.Subscript(value=ast.Name(id=ctx), slice=ast.Constant(comp.target))`.
- Single‑operand ops are pure passthroughs (line 43-44). This is how
  `Summation(c)` and `Product(c)` degenerate cleanly.

### Serialization

`to_json` (`BaseOp.py:53-63`):
- `modulePath` from `modManager.resolve_public_import(self)` — must round‑trip
  via `modManager.import_module` (line 91).
- For each operand: if `isinstance(comp, BaseOp)` recurse via
  `comp.to_json()`; else append the leaf's `comp.root` (a `str` like
  `"<ctx_path>:<name>"`).

`from_json` (`BaseOp.py:76-82`):
- For each entry: if `str` → look up the existing compartment with
  `gsm.get_compartment(path)`; if `dict` → reload via `BaseOp.load_op`.
- **Assumes `__init__()` callable with no args.** `load_op` line 92 does
  `klass()` — works for `Summation` and `Product` because `*compartments`
  collapses to empty tuple. **Constraint on future Ops:** must support
  zero‑arg construction.

### Wiring (`__rshift__`)

`BaseOp.__rshift__` (`BaseOp.py:85-87`):

```python
def __rshift__(self, other):
    if any(isinstance(base, CompartmentMeta) for base in type(other).__mro__):
        other.__rrshift__(self)
```

- Only fires if `other`'s MRO contains a class instantiated by
  `CompartmentMeta`. Note this checks `isinstance(base, CompartmentMeta)`
  (the metaclass), not `issubclass`. Both `Compartment` and `BaseOp` qualify.
- Delegates to `Compartment.__rrshift__` (`compartment.py:134-137`) which
  sets `self.target = other` (i.e. the destination compartment now points
  *at this op* and pulls its value through `_get_value`).

Returns `None` implicitly — the `>>` chain in user code is a wiring effect,
not an expression value.

---

## Summation + Product — implementation details

| Aspect | `Summation` | `Product` |
|---|---|---|
| `astOp` | `ast.Add()` | `ast.Mult()` |
| Identity element | `0` (Python `sum` default) | `1` (explicit `x = 1`) |
| Reduction style | `sum(self._comps)` — relies on `Compartment.__add__` (metaclass) and `_unwrap` | manual `for comp in self._comps: x *= comp.get()` |
| Element fetch | implicit via `__add__` → `_unwrap` → `_get_value` | explicit `.get()` on each |
| Broadcasting | inherited from the underlying numeric type of each compartment value (JAX/numpy arrays use their own `__add__`/`__mul__`) | same |
| Variadic arity | `*compartments` — 0+ allowed at construction; degenerate single‑operand handled in `_to_ast` (line 43) | same |

Both are **elementwise** when operands are arrays — the actual element
combination is delegated to the operand's underlying type (JAX array
+/*, scalar +/*, etc.). Neither op performs an axis-reduction (e.g. they
do NOT call `jnp.sum(x, axis=...)`); the `Summation` name refers to
"summing N compartments" not "summing along a tensor axis".

### Implicit JAX/array contract

- `Compartment.__jax_array__` (`compartment.py:119-120`) returns `self.get()`,
  so wherever a `Compartment` lands in a JAX expression it auto-resolves to
  the underlying array. This is the channel by which broadcasting/dtype
  rules become JAX's responsibility, not the Op's.
- `_unwrap` (`compartmentMeta.py:5-8`) is a `while hasattr(x, "_get_value")`
  loop, so chained ops resolve recursively until a raw value is reached.

---

## Internal classes / functions

None. The Operations module exports only the three classes named above.
There are no private helpers, no decorators, no module-level state.

External helpers it *consumes* (defined elsewhere, not part of this spec but
required by the port):
- `CompartmentMeta` — installs dunder arithmetic on the class
  (`compartmentMeta.py:33-53`).
- `modules_manager` — singleton with `resolve_public_import(obj) -> str` and
  `import_module(path) -> class`.
- `global_state_manager` — singleton with `get_compartment(path) -> Compartment`.

---

## Data structures + invariants

### Op record (per instance)

```python
{
    "_comps": list[Compartment | BaseOp],   # ordered, len >= 0
    "astOp":  ast.operator | None,          # set by subclass __init__
}
```

### Invariants observed in source

1. `_comps` is a `list`, not a tuple — `from_json` appends to it
   (`BaseOp.py:80, 82`). Therefore mutation post‑construction is possible
   (no defensive copy).
2. `astOp` is set exactly once in subclass `__init__`. Not mutated thereafter.
3. **No instance has a name, root, or global‑state entry.** Confirmed by the
   absence of any `gState.add_compartment(self)` call (contrast with
   `Compartment._setup` at `compartment.py:74`).
4. **Ops are not registered in any context.** `Compartment.__rrshift__`
   adds a *connection* edge from `other` to `self` (`compartment.py:135-136`)
   but the op itself is stored only as `self._target` on the destination
   compartment — there's no global "op registry".
5. **Operand order matters.** Summation/Product are commutative but
   `_to_ast` produces a left-fold; serialization preserves order; `from_json`
   replays the same order. Future non‑commutative ops can rely on this.
6. **Construction is two-phase for `from_json`.** `BaseOp.load_op` calls
   `klass()` with no args (line 92), then `from_json` (line 93) appends
   operands to the freshly-empty `_comps`. Any subclass that puts logic past
   `super().__init__(*compartments)` must tolerate empty `_comps`.

### Composition

- Ops are stored as the `_target` field of a destination `Compartment`
  (`compartment.py:114-115`, `144-170`). The destination compartment's
  `.get()` transparently returns `self.target.get()` when target is a
  `BaseOp`.
- Op trees grow when an Op is passed as an operand into another Op:
  `Summation(Product(a, b), c)`. The outer constructor accepts arbitrary
  iterables of `Compartment | BaseOp` via `*compartments`.
- There is no de-duplication or canonicalization. `Summation(a, a)` would
  evaluate `a` twice (once per operand) — fine for pure reads against the
  global state, but worth noting for the Julia port if caching is added.

---

## External dependencies

| Python import | Where used | Julia equivalent / port note |
|---|---|---|
| `ast` (stdlib) | `BaseOp.py:5,49`; `Summation.py:13`; `Product.py:13` | No direct equivalent. Lowering target is **Reactant.jl** tracing, not Python AST. Concrete plan: replace `astOp` with a callable kernel (`+`, `*`) used by both the eager path *and* the trace‑compile path. See "Julia translation notes". |
| `ngcsimlib._src.compartment.compartmentMeta.CompartmentMeta` | `BaseOp.py:1, 7` | Julia abstract type `AbstractCompartmentNode` shared by `Compartment` and `BaseOp`. No metaclass machinery needed — replace dunder operator installation with concrete `Base.+`/`Base.*` methods on the abstract type. |
| `ngcsimlib._src.modules.modules_manager` | `BaseOp.py:2, 54, 91` | Module registry for JSON round‑tripping. Julia equivalent: a `Dict{Symbol, Type}` registered by `@register_op` macro keyed on a stable symbol name (e.g. `:Summation`), plus a `Pkg`/module path inspector. |
| `ngcsimlib._src.global_state.manager` | `BaseOp.py:3, 80` | The runtime "global state" dict. In Julia: a `GlobalState` struct holding a `Dict{String,Any}` (or typed namedtuple later), threaded through evaluation rather than singleton-global if we want Reactant traceability. |

No `numpy`, no `jax` imports in this module directly — they enter only via
the values inside compartments. This makes the Operations module the
**easiest** of the six to port.

---

## Julia translation notes

### Type hierarchy

```julia
# Shared abstract type for both Compartment and Op leaves/nodes.
# (Defined in compartment_spec.md; redeclared here for context.)
abstract type AbstractValueNode end

abstract type AbstractOp <: AbstractValueNode end
```

`AbstractOp` is the analogue of Python `BaseOp`. Concrete Ops subtype it.

### BaseOp port

Python uses metaclass machinery so that `c1 + c2` returns a *value*
(eager `_unwrap`-based addition). In Julia we get the same effect by
defining `Base.+`/`Base.*`/... on `AbstractValueNode` to forward to a
`get_value` function (defined in the Compartment spec). Ops themselves do
not need new `Base.+` definitions — they inherit them through
`AbstractValueNode`.

```julia
"""
Abstract op. Stores operands and a callable that reduces them.
Operands may be Compartments or other Ops.
"""
abstract type AbstractOp <: AbstractValueNode end

# Required interface (concrete ops MUST implement):
#   get_value(op::ConcreteOp) -> Any
#   ast_kernel(op::ConcreteOp) -> Function   # the binary reducer, e.g. +, *
# Optional interface (default implementations provided):
#   to_json(op::AbstractOp) -> Dict
#   from_json!(op::AbstractOp, data::Dict, gsm) -> op
#   needed_keys(op::AbstractOp) -> Set{String}
#   lower(op::AbstractOp, ctx) -> Reactant traced value
```

#### `get_value` default

Concrete ops *must* override. There is no useful default — Python returns
the sentinel `NotImplemented` and silently propagates it (a foot-gun we
should not replicate). Raise instead:

```julia
get_value(op::AbstractOp) = error("get_value not implemented for $(typeof(op))")
```

#### `lower` (replaces `_to_ast`)

Reactant traces Julia functions; we do not build an AST manually. The
Pythonic AST left‑fold becomes a simple Julia fold over the operands'
traced values:

```julia
function lower(op::AbstractOp, ctx)
    operands = lower.(op.comps, Ref(ctx))   # recurse on each child
    length(operands) == 1 && return operands[1]
    reduce(ast_kernel(op), operands)        # left-fold with the op's kernel
end
```

Where `lower(c::Compartment, ctx)` returns `ctx[c.target]` (the equivalent
of `Subscript(Name(ctx), Constant(target))` in Python). For Reactant,
`ctx` is the `ConcreteRArray`-keyed dict passed into the traced function;
`ctx[target]` becomes a Reactant tracer node and `reduce(+, [...])` becomes
a fused Reactant sum.

### Concrete ops

```julia
"""
Summation — sums an arbitrary number of value nodes.
Identity = 0. Order-preserving (left-fold).
"""
struct Summation <: AbstractOp
    comps::Vector{AbstractValueNode}
end
Summation(comps::AbstractValueNode...) = Summation(collect(comps))

ast_kernel(::Summation) = +
get_value(op::Summation) = sum(get_value(c) for c in op.comps; init = 0)
# Or, to mirror Python's reliance on operator overloading exactly:
# get_value(op::Summation) = isempty(op.comps) ? 0 : reduce(+, get_value.(op.comps))
```

```julia
"""
Product — multiplies an arbitrary number of value nodes.
Identity = 1. Order-preserving (left-fold).
"""
struct Product <: AbstractOp
    comps::Vector{AbstractValueNode}
end
Product(comps::AbstractValueNode...) = Product(collect(comps))

ast_kernel(::Product) = *
get_value(op::Product) = prod(get_value(c) for c in op.comps; init = 1)
```

Both reductions are Reactant-safe in eager mode: `+` and `*` over arrays
become elementwise ops with broadcasting; over scalars they are scalars.
`reduce(+, xs)` and `sum(xs; init=0)` are both fine under Reactant tracing
(they unroll over the static length of `xs` — which is fixed at op
construction time).

### Wiring (`>>`)

Python's `op >> compartment` (`BaseOp.__rshift__`) wires the op as the
target of the compartment. In Julia, define `>>` on `AbstractValueNode`:

```julia
# Wire `src` as the source of `dst`.
function Base.:(>>)(src::AbstractValueNode, dst::Compartment)
    set_target!(dst, src)   # equivalent of Compartment.__rrshift__
    notify_context!(src, dst)
    dst
end
```

(Compartment spec owns the `set_target!` and `notify_context!` definitions.)

### Serialization

Op (de)serialization can stay structurally identical:

```julia
function to_json(op::AbstractOp)
    Dict(
        "modulePath"   => string(nameof(typeof(op))),   # or full module path
        "compartments" => [c isa AbstractOp ? to_json(c) : root(c) for c in op.comps],
    )
end

function from_json!(op::AbstractOp, data::Dict, gsm)
    for entry in data["compartments"]
        push!(op.comps, entry isa AbstractString ?
                          get_compartment(gsm, entry) :
                          load_op(entry, gsm))
    end
    op
end

function load_op(data::Dict, gsm)
    T   = lookup_op_type(Symbol(data["modulePath"]))    # registry lookup
    op  = T()                                           # zero-arg ctor
    from_json!(op, data, gsm)
end
```

For the zero‑arg constructor requirement we add:

```julia
Summation() = Summation(AbstractValueNode[])
Product()   = Product(AbstractValueNode[])
```

### `needed_keys` (fix the Python bug — see Hazards §)

```julia
function needed_keys(op::AbstractOp)
    keys = Set{String}()
    for c in op.comps
        union!(keys, needed_keys(c))
    end
    keys
end
```

### Reactant compatibility checklist

- **No Python‑AST emission needed.** Reactant traces the eager `get_value`
  path directly. The whole `_to_ast` / `astOp` machinery vanishes; we just
  call `get_value` inside a function decorated for tracing.
- **No data-dependent control flow** in either Op. The Python sources have
  one `for` loop in `Product._get_value` whose iteration count is the
  *number of operands*, fixed at construction time. Reactant unrolls this
  cleanly because `length(op.comps)` is a Julia‑side constant.
- **No `if` on tensor contents** anywhere in the module.
- **No mutation of operands.** `_get_value` only *reads* compartment values.
- **`sum` / `prod` / `reduce` over arrays** are all Reactant‑safe primitives;
  they lower to MLIR `stablehlo.reduce` ops.
- **Avoid `init` kwarg if it breaks tracing.** As a precaution provide a
  fallback path:

  ```julia
  get_value(op::Summation) =
      isempty(op.comps) ? 0 :
      foldl(+, (get_value(c) for c in op.comps))
  ```

  This avoids any reliance on `init`-typed identity when operands are
  Reactant tensors of unknown shape.
- **Enzyme.jl AD.** Both `+` and `*` have trivial pullbacks; Enzyme handles
  fold-of-`+`/`*` natively. No custom rules required for Operations.

---

## Open questions / hazards

1. **Bug in `BaseOp.get_needed_keys`** (`BaseOp.py:66-73`). The line
   `keys.union(comp.get_needed_keys())` returns a new set and discards it
   — `set.union` is not in-place. Should be `keys |= ...` or
   `keys.update(...)`. Result: the method always returns an empty set.
   The Julia port should use `union!` (in-place) — see code above. **Decision
   needed**: do we replicate Python's buggy behavior for bit-exactness, or
   fix? *Recommend fix*; flag in CHANGELOG.

2. **Asymmetry between `Summation._get_value` and `Product._get_value`.**
   `Summation` uses `sum(self._comps)` (relies on operator overloading via
   `CompartmentMeta`); `Product` uses an explicit `comp.get()` loop. Both
   produce the same answer for `Compartment` operands because of the
   `__jax_array__`/`_unwrap` plumbing, but the styles differ. In Julia we
   should use one consistent pattern (`get_value(c) for c in op.comps`).

3. **`_get_value` default returns `NotImplemented` (line 28) rather than
   raising.** This silently poisons computations if a developer forgets to
   override. Julia port should *raise* (`error(...)`).

4. **`__rshift__` returns `None` after wiring** (no `return` statement at
   line 87). Chained wiring like `a >> b >> c` would break in Python; in
   Julia we should return `dst` so chains compose (see Julia code above).

5. **`from_json` mutates a default-constructed instance.** This means
   subclasses cannot enforce non‑empty `_comps` invariants at construction.
   Recommendation: keep zero-arg constructors as a public requirement and
   document this for future Op authors.

6. **Module‑path serialization is class‑name‑based via `modules_manager`.**
   Cross‑language replay (e.g. loading a Python‑serialized model in Julia)
   would need a name‑mapping registry. **Out of scope for Phase A**; flag
   for later interop work.

7. **Overlap with `Compartment` and `Context`.** Operations interact with:
   - `Compartment` via `_get_value` / `_to_ast` / `__rrshift__` /
     `__jax_array__` (`compartment.py:110-117, 119-120, 125-132, 134-137`).
     The Julia design must keep `AbstractValueNode` as a thin shared base
     so the wiring code in the Compartment spec composes correctly.
   - `Context` via `__rrshift__` calling `gcm.current_context.add_connection`
     (`compartment.py:135-136`). Ops are *not* themselves registered with
     a context, but the act of wiring an op into a compartment **does**
     register an edge. Flag for the Context spec author: edges from
     `BaseOp` to `Compartment` must be recordable, with the op's operand
     list possibly walked to record transitive edges from the leaf
     compartments to the destination.
   - `Process` / compiler — `_to_ast` is consumed by a process compiler
     (not in this module). The Julia replacement (`lower` over Reactant)
     belongs in the Process spec; this spec only commits to providing a
     `lower` method.

8. **`Compartment.get_needed_keys` returns `set(self.target)`** when the
   target is a `BaseOp` (`compartment.py:106-108`). Reading the source
   carefully: line 108 is `return set(self.target)` where `self.target` is
   a `str` — `set("foo:bar")` produces `{'f','o','o',':','b','a','r'}` (set
   of characters), almost certainly another bug. The Julia port should
   return `Set([target])`. Flag for Compartment spec.

9. **`load_op` instantiates with `klass()`**. Already noted, but worth
   restating: any future Op subclass must tolerate `__init__(*compartments)`
   being called with no args. Currently both shipped ops do; document this
   as a hard rule.

10. **No tests in `operations/`.** There is no `tests/` subdirectory in
    `_src/operations/`. Behavior is implicit. Recommend the Julia port
    introduce unit tests covering: eager `get_value`, nested op trees,
    `to_json`/`from_json` round-trip, `>>` wiring, `lower` under Reactant,
    Enzyme gradient over a `Summation` and `Product` reduction.

---

## Summary table — port effort

| Item | Python LOC | Julia LOC est. | Effort |
|---|---|---|---|
| `BaseOp` core (struct + interface) | ~30 | ~25 | trivial |
| `Summation` | 14 | ~10 | trivial |
| `Product` | 17 | ~10 | trivial |
| `to_json` / `from_json` / `load_op` | ~25 | ~30 (need op-type registry) | small |
| `lower` (Reactant) replacing `_to_ast` | ~22 | ~10 | small |
| Wiring (`>>`) | ~6 | shared with Compartment | shared |
| Fix `get_needed_keys` bug | n/a | 1-liner | trivial |
| Tests (new) | 0 | ~80 | small |

Operations is the lightest module of the six and has zero JAX coupling.
Most of the porting work is **structural** (the `AbstractValueNode`
hierarchy shared with `Compartment`) rather than algorithmic.
