# Phase A spec — `Component` + `Compartment` modules

Source files (read in full):

- `ngcsimlib/_src/component.py` (27 lines)
- `ngcsimlib/_src/compartment/compartment.py` (171 lines)
- `ngcsimlib/_src/compartment/compartmentMeta.py` (53 lines)
- `ngcsimlib/_src/compartment/__init__.py` (1 line)

Cross-module dependencies that the port writer must keep coherent with their own specs:
`context/contextAwareObject.py`, `context/contextObjectDecorators.py`, `context/context_manager.py`,
`global_state/manager.py`, `operations/BaseOp.py`, `parser/utils.py` (`compilable`,
`compileObject`). Citations for these appear inline where relevant.

---

## Purpose

A **`Component`** is a user-facing, context-tracked object that owns a set of
**`Compartment`** fields and represents a named "part of a model" (a neuron layer,
synapse bank, etc.) (`component.py:10-15`). A **`Compartment`** is a typed,
named handle that acts as a *pointer into a flat global state dictionary*: its value
lives in `global_state_manager.__state` under a string key, and the compartment
object itself just stores that key plus optional rewire/display metadata
(`compartment.py:12-23`). Wiring `a >> b` in user code does **not** copy or compute —
it retargets compartment `b` to read from whatever key (or `BaseOp` AST node) `a`
currently points at, leaving `b`'s original slot orphaned but allocated in the
global state (`compartment.py:13-22`, `:134-141`).

---

## Public API

### `Component` (`component.py`)

Inherits `ContextAwareObject` (`component.py:10`,
`context/contextAwareObject.py:9`).
Decorated with `@component` (sets `cls._type = ContextObjectTypes.component`,
`contextObjectDecorators.py:8-11`) and `@compilable` (sets `fn._is_compilable = True`,
`parser/utils.py:8-16`). The combination registers the *class* as a compilable
component with the context system.

| Member | Signature | Behavior | Source |
|---|---|---|---|
| `__init__` | `__init__(self, name)` | Calls `super().__init__(name)` — i.e. `ContextAwareObject.__init__` which sets `self.name = name` and `self.context_path = gcm.current_path` | `component.py:16-17`; `contextAwareObject.py:16-18` |
| `compartments` (property) | `→ List[Tuple[str, Compartment]]` | Returns `[(attr_name, value) for attr_name, value in vars(self).items() if isinstance(value, Compartment)]`. **Iterates `vars(self)`**, so it sees every attribute the user assigned during `__init__` whose value is a `Compartment` instance. | `component.py:19-26` |

Inherited (from `ContextAwareObject`, `contextAwareObject.py`):

| Member | Signature | Behavior | Source |
|---|---|---|---|
| `to_json` | `→ Dict[str, Any]` | Serializes `self._args` and `self._kwargs` (set by the metaclass `ContextAwareObjectMeta`, not shown here — see context module spec) into JSON-safe args/kwargs; unserializable entries are dropped with a `warn`. | `contextAwareObject.py:20-45` |
| `compile` | `→ None` | Calls `compileObject(self)` (`parser/utils.py:136-157`). | `contextAwareObject.py:47-52` |

### `Compartment` (`compartment.py`)

Class declaration: `class Compartment(metaclass=CompartmentMeta)` (`compartment.py:12`).

Constructor (`compartment.py:39-54`):

```python
def __init__(self, initial_value: T,
             display_name: str | None = None,
             units: str | None = None,
             plot_method: Union[Callable, None] = None,
             auto_save: bool = True)
```

- `initial_value` is stashed in `self._initial_value` (`:45`) and *not* written to
  global state yet — global write happens in `_setup` (`:73`).
- `self.name = None`, `self._root_target = None`, `self._target = self._root_target`
  (`:47-49`).
- Stores `display_name`, `units`, `plot_method`, and `_auto_save` (`:51-54`).

| Member | Signature | Behavior | Source |
|---|---|---|---|
| `root` (property) | `→ str \| None` | Returns `self._root_target`. This is the *canonical, immutable* global-state key for this compartment after `_setup` runs. | `compartment.py:56-58` |
| `auto_save` (property) | `→ bool` | Returns `self._auto_save`. Flag for external save systems; not used inside simlib. | `:60-62` |
| `targeted` (property) | `→ bool` | True iff `self._target` is **not** a string, **or** `self._target != self._root_target`. I.e. true whenever something has rewired into this compartment. | `:64-66` |
| `target` (property) | `→ Union[BaseOp, str]` | Returns `self._target`. Reflects the *current* read source: either the canonical global-state key string, a foreign key string, or a `BaseOp` AST-buildable. | `:143-148` |
| `target` (setter) | `target = Union[Compartment, BaseOp, str]` | If `value` is `str` or `BaseOp`, assigns directly. If `value` is a `Compartment`, assigns `value.target` (chasing one hop). Note `:167-169` is unreachable (str branch already handled at `:159`); the `raise ValueError` (`:170`) only fires for completely foreign types — and only because the unreachable block falls through (no else). Port writers should treat: "value must be `str`, `BaseOp`, or `Compartment` — otherwise raise". | `:150-170` |
| `set` | `set(self, value: T) → None` | Behavior depends on `self.target`: <br>• If `target is None` → stash in `self._initial_value` and return (`:86-88`). <br>• If `target != self._root_target` → log warn `Attempting to set <target> in <root>. Aborting!` and return (`:90-92`). I.e. *cannot write to a foreign target — you can only write your own slot.* <br>• Else → `gState.set_state({self.target: value})` (`:93`). | `:76-93` |
| `get` | `get(self) → T` | Returns `self._get_value()`. | `:95-99` |
| `get_needed_keys` | `→ Set[str]` | If `target` is a `BaseOp`, delegate to `target.get_needed_keys()`. Else return `set(self.target)`. **Note**: `set("foo:bar")` makes a set of single-char strings — this looks like a bug upstream. The Julia port should faithfully reproduce or document the divergence; recommended faithful translation is `Set([self.target])`. See "Open questions / hazards". | `:101-108`; cross-ref `operations/BaseOp.py:66-73` |
| `__jax_array__` | `→ value` | Returns `self.get()`. Allows the compartment to be used transparently inside JAX numerical ops (JAX checks for this dunder on arbitrary objects). | `:119-120` |
| `__str__` | `→ str` | `str(self._get_value())`. | `:122-123` |
| `__rrshift__` | `__rrshift__(self, other)` | The *reflected* `>>` operator (i.e. RHS handler): when `other >> self` is evaluated and `other` does not handle it, `self.__rrshift__(other)` fires. <br>1. If `gcm.current_context is not None`, call `gcm.current_context.add_connection(other, self)` (recorded wire in the context). <br>2. `self.target = other` — i.e. the right-hand compartment retargets at the left-hand source. <br>**Convention**: `source >> dest` makes `dest` read `source`. | `:134-137` |
| `__rshift__` | `__rshift__(self, other)` | LHS handler. If `other` is a `Compartment`, calls `other.__rrshift__(self)` — i.e. delegates to the rewire above. Otherwise no-op. (`BaseOp` has its own `__rshift__`, `BaseOp.py:85-87`.) | `:139-141` |

### Private/internal methods on `Compartment` (the port must implement these — they're called from elsewhere in the codebase, primarily from `Context` setup and the AST compiler)

| Member | Signature | Behavior | Source |
|---|---|---|---|
| `_setup` | `_setup(self, compName, path)` | Assigns `self.name = compName`; constructs `self._root_target = path + ":" + compName`; if `self.target is None` (i.e. compartment was never rewired before `_setup` ran), assigns `self._target = self._root_target` and writes the initial value via `self.set(...)`; finally registers self in `gState.add_compartment(self)`. **This is the moment a compartment becomes "live"** in the global state. | `:68-74` |
| `_get_value` | `→ value` | If `target is None`: return `self._initial_value`. If `target` is a `BaseOp`: return `target.get()` (recursive AST evaluation). Else: return `gState.from_global_key(self.target)`. | `:110-117` |
| `_to_ast` | `_to_ast(self, node, ctx) → ast.AST` | Used by the bytecode/JIT compiler. If `target` is a string, build `ast.Subscript(value=ast.Name(id=ctx, ctx=Load()), slice=ast.Constant(value=self.target), ctx=node.ctx)` — i.e. emits Python AST `ctx["the/global/key"]` where `ctx` is the name of the global-state-dict variable in the compiled function. If `target` is a `BaseOp`, delegate: `self.target._to_ast(node, ctx)`. | `:125-132`; cross-ref `BaseOp.py:30-51` |

### `CompartmentMeta` (`compartmentMeta.py`)

A `type`-subclass metaclass (`compartmentMeta.py:33`) used by both `Compartment` and
`BaseOp` (see `operations/BaseOp.py:7`). Its job: **auto-inject every Python numeric
dunder** so that compartments behave like their unwrapped numeric values in
arithmetic expressions.

`__new__(mcs, name, bases, namespace)` (`:40-53`):

For each `(dunder_name, opfunc)` pair in:
- `_BINARY_OPS` = `{__add__, __sub__, __mul__, __matmul__, __truediv__, __floordiv__,
  __mod__, __pow__, __and__, __xor__, __or__, __eq__, __ne__, __lt__, __le__, __gt__,
  __ge__}` mapping to `operator.{add,sub,mul,...}` (`:11-29`).
- `_REVERSE_OPS` = the same keys re-prefixed `__r{name}` → same `op` (`:31`). So
  `__radd__`, `__rsub__`, etc. all dispatch to plain `operator.add`, `operator.sub`,
  ... (semantically wrong for non-commutative ops like `__rsub__`, but it's what the
  upstream does — see "Open questions / hazards").

For every such `dunder_name` *not already present* in the class `namespace`, install:
```python
def method(self, other):
    return opfunc(_unwrap(self), _unwrap(other))
```
where `_unwrap` recursively follows `._get_value()` until it bottoms out
(`compartmentMeta.py:5-8`).

Net effect: `compartment_a + compartment_b` works as `_unwrap(a) + _unwrap(b)`,
returning a raw numeric value (likely a `jax.numpy` array), with no compartment
wrapping the result.

### Module re-export (`compartment/__init__.py`)

Single line: `from .compartment import Compartment as Compartment` (`__init__.py:1`).
The explicit `as` re-export marks it as part of the public surface.

---

## Internal classes / functions

- `_unwrap(x: Any) → Any` (`compartmentMeta.py:5-8`) — module-private helper. Loops:
  `while hasattr(x, "_get_value"): x = x._get_value()`. Returns the first non-
  compartment-ish value. Used inside every auto-generated dunder.

- `_BINARY_OPS` / `_REVERSE_OPS` (module-level dicts, `compartmentMeta.py:11-31`)
  — the static op table consumed at class-construction time.

There are no other module-private definitions in these four files. `BaseOp` (used in
isinstance checks at `compartment.py:106, 114, 159`) lives in
`operations/BaseOp.py` and has its own spec.

---

## Data structures + invariants

### `Component` fields

Inherited from `ContextAwareObject.__init__` (`contextAwareObject.py:16-18`):
- `self.name: str` — user-supplied identifier
- `self.context_path: str` — captured value of `gcm.current_path` at construction time

Class attribute (set by `@component` decorator):
- `cls._type = ContextObjectTypes.component`

Class attribute (set by `@compilable`):
- `cls._is_compilable = True` (`parser/utils.py:8-16`)

Additional state (`self._args`, `self._kwargs`) is set by the
`ContextAwareObjectMeta` metaclass during instance construction
(referenced at `contextAwareObject.py:28, 36`; port writer should confirm against
the context spec).

User-added compartment attributes live in the instance `__dict__` and are discovered
via `vars(self)` (`component.py:26`).

### `Compartment` fields

| Field | Type | Set at | Meaning |
|---|---|---|---|
| `_initial_value` | `T` | `__init__` (`:45`) | The value to write into the global state when `_setup` is called. |
| `name` | `str \| None` | `__init__` → `None` (`:47`); `_setup` (`:69`) | The local attribute name on the owning component, set when the context wires this compartment in. |
| `_root_target` | `str \| None` | `__init__` → `None` (`:48`); `_setup` (`:70`) | The canonical, never-changing global-state key for this compartment. Format: `"{owner_path}:{compartment_name}"`. |
| `_target` | `str \| BaseOp \| None` | `__init__` → `None` (`:49`); `_setup` (`:72`); `target.setter` (`:151-170`); `__rrshift__` (`:137`) | The *current* read source. If equal to `_root_target` → reading own slot. Otherwise → wired to read someone else's slot or a `BaseOp`. |
| `display_name` | `str \| None` | `__init__` (`:51`) | Optional UI label. |
| `units` | `str \| None` | `__init__` (`:52`) | Optional unit string. |
| `plot_method` | `Callable \| None` | `__init__` (`:53`) | Optional plotting hook. |
| `_auto_save` | `bool` | `__init__` (`:54`) | Save-system hint. |

### Invariants

1. **Owner-uniqueness**: every `Compartment` is intended to be owned by exactly one
   `Component` (discovered via `vars(self)` in `Component.compartments`,
   `component.py:26`). Nothing in *this* code enforces it; the context layer is
   expected to. Port-writer note: if the owning component is detected via
   `vars(component).items()`, then assigning the same `Compartment` instance to two
   components would have it discovered by both — relies on user discipline.
2. **Setup-once**: `_setup` is the *only* call site that registers a compartment
   into the global state via `gState.add_compartment(self)` (`:74`). After setup
   `self.name` and `self._root_target` should never change.
3. **Self-write-only**: `set()` will refuse to write to any key other than
   `self._root_target` (`:90-93`). Cross-compartment writes go through retargeting,
   not direct set.
4. **Pre-setup state writes are buffered**: if `set()` is called before `_setup`
   (so `self.target is None`), the value goes into `self._initial_value`
   (`:86-88`) — letting users override an initial value after construction but
   before context wiring.
5. **Rewire is shallow** (`:163-165`): retargeting `b` to `a` copies `a.target`,
   not `a` itself. So if `a` is later retargeted, `b` keeps reading the *old*
   source. This matters for the wiring model.
6. **`_target` is one of**: `None` (pre-setup), `str` (its own root key or someone
   else's root key), or `BaseOp` (an inline computed expression).
7. **`name` and `_root_target` are coupled**: `_root_target == path + ":" + name`
   exactly (`:70`).

### Lifecycle

```
construction:    __init__       → fields set, _target = None, NOT in global state
context wiring:  _setup         → name + root assigned, gState.add_compartment, gState.set_state({root: initial_value})
user mutations:  set / __rrshift__ → either gState write (own slot) or _target rebind
compilation:     _to_ast        → emits ctx[<key>] AST nodes for the JIT
read:            get / _get_value / __jax_array__ → resolves through _target
teardown:        no explicit destructor; compartments live as long as the global state does
```

---

## Metaclass behavior

`CompartmentMeta` overrides only `__new__` (`compartmentMeta.py:40-53`). No
`__init_subclass__`, no `__call__`. The behavior is *purely class-construction-
time injection of dunder methods* into the class `namespace` dict before
`super().__new__(...)` is called.

The "metaclass" status matters for `BaseOp` (`operations/BaseOp.py:7`) which also uses
it — so `BaseOp` instances inherit the same arithmetic auto-wrap. The
`isinstance(...)` check in `BaseOp.__rshift__` (`BaseOp.py:86`) uses
`type(other).__mro__` to detect compartment-class lineage, which is metaclass-
specific Python behavior.

### Julia equivalent

Julia has no metaclasses, but the same effect (auto-inject arithmetic that
unwraps the receiver) is achieved with **`Base.@__doc__` / explicit method
definitions on the abstract supertype**, ideally generated by a macro:

```julia
abstract type AbstractCompartmentLike end   # Compartment + BaseOp both <: this

# _unwrap chases ._get_value-equivalent
function unwrap(x::AbstractCompartmentLike)
    while x isa AbstractCompartmentLike
        x = get_value(x)   # generic; Compartment + BaseOp both implement
    end
    return x
end
unwrap(x) = x   # fallback for already-unwrapped values

# Macro-generate arithmetic methods
macro inject_compartment_ops()
    ops = [:+, :-, :*, :/, :÷, :%, :^, :&, :⊻, :|, :(==), :!=, :<, :<=, :>, :>=]
    matmul = :(*)   # Julia uses * for matrix; or define separate
    exprs = []
    for op in ops
        push!(exprs, quote
            Base.$op(a::AbstractCompartmentLike, b) = $op(unwrap(a), unwrap(b))
            Base.$op(a, b::AbstractCompartmentLike) = $op(unwrap(a), unwrap(b))
            Base.$op(a::AbstractCompartmentLike, b::AbstractCompartmentLike) =
                $op(unwrap(a), unwrap(b))
        end)
    end
    return Expr(:block, exprs...)
end
@inject_compartment_ops()
```

Notes:

- Python's `__matmul__` → Julia uses `*` for `Matrix * Matrix`. If a separate
  matmul is needed for ND-tensors via Reactant, expose it explicitly.
- Python's reverse dunders (`__radd__`, etc.) are unnecessary in Julia because
  multiple dispatch covers both argument orders symmetrically when methods are
  defined on `(::AbstractCompartmentLike, ::Any)` AND `(::Any, ::AbstractCompartmentLike)`.
- The upstream bug where `__rsub__` calls `operator.sub` (not a swapped
  version) means Python `5 - compartment` evaluates as `sub(5, unwrap(c))` —
  i.e. it *does* end up commutatively correct because of `_unwrap(self)` being
  the **left** side in the generated function (`compartmentMeta.py:43`). So
  for `__rsub__`, when Python calls `compartment.__rsub__(5)`, the function
  computes `sub(_unwrap(compartment), _unwrap(5))` = `c_val - 5` — which is
  **wrong** (`5 - compartment` should give `5 - c_val`). The Julia port can
  decide to (a) faithfully reproduce this bug, (b) fix it. Recommend fixing
  and documenting the divergence. See "Open questions / hazards".

---

## External dependencies

| Python import | Used for | Julia equivalent |
|---|---|---|
| `ast` (`compartment.py:4`) | Build Python AST nodes (`ast.Subscript`, `ast.Name`, `ast.Constant`, `ast.Load`, `ast.BinOp`) for the JIT compiler. | Julia has native AST — use `Expr(:ref, ctx, key)` for indexing and `Expr(:call, op, l, r)` for binops. The whole "compile to AST then `exec`" pipeline becomes "build `Expr` then `Core.eval` or `RuntimeGeneratedFunctions`". With Reactant.jl, this is replaced by tracing — see Phase B JIT spec. |
| `operator` (`compartmentMeta.py:1`) | Function references for binary ops (`operator.add`, etc.). | Direct symbols `:+, :-, :*, ...` and `Base.+, Base.-, Base.*, ...`. |
| `typing.{TypeVar, Union, Set, Callable, List, Tuple, Dict, Any}` | Type hints. | Julia type parameters (`T`), `Union{A,B}`, `Set{T}`, `Function`, `Vector{Tuple{S,T}}`, `Dict{K,V}`, `Any`. |
| `ngcsimlib._src.compartment.compartmentMeta.CompartmentMeta` | Metaclass for `Compartment` and `BaseOp`. | Abstract supertype `AbstractCompartmentLike` + injection macro (see above). |
| `ngcsimlib._src.global_state.manager.global_state_manager as gState` (`compartment.py:2`) | Read/write global value dict; register compartments. | A module-level mutable singleton, e.g. `const GLOBAL_STATE = GlobalStateManager()`. See Phase A global-state spec (sibling). |
| `ngcsimlib._src.logger.warn` (`compartment.py:3`) | Log non-fatal misuse (set into foreign target). | `@warn` macro from `Logging` stdlib. |
| `ngcsimlib._src.operations.BaseOp.BaseOp` (`compartment.py:6`) | `isinstance` checks; recursive AST emission. | Concrete subtype of `AbstractCompartmentLike`. Phase A op spec. |
| `ngcsimlib._src.context.context_manager.global_context_manager as gcm` (`compartment.py:7`) | `gcm.current_context` for wiring registration. | Module-level mutable singleton `CONTEXT` (see Phase A context spec). |
| `ngcsimlib._src.context.contextAwareObject.ContextAwareObject` (`component.py:1`) | Base class. | Julia abstract type `AbstractContextAwareObject`. |
| `ngcsimlib._src.context.contextObjectDecorators.component` (`component.py:2`) | Class-level type tag. | Concrete subtype declaration (`struct MyComp <: AbstractComponent`) — no decorator needed; the abstract supertype IS the tag. |
| `ngcsimlib._src.parser.utils.compilable` (`component.py:4`) | Mark class as JIT-compilable. | Trait function `is_compilable(::Type{T}) = true` or holy-trait pattern. |
| `jax` (implicit, via `__jax_array__`) | JAX's array protocol for transparent compartment-as-array use. | Reactant.jl `@trace` integration: define `Reactant.Ops.materialize(::Compartment)` or whatever the equivalent hook is. JAX `__jax_array__` is JAX's `__array__`-like duck typing for tracers; Reactant's analog uses `TracedRArray` adaptors. |

---

## Julia translation notes

### Naming conventions

- Python `Component` / `Compartment` → Julia `Component` / `Compartment` (PascalCase
  for types, matches Julia convention).
- Python `_private_field` → Julia bare lowercase field names. Encapsulation in Julia
  is *by module export*, not by underscore convention. So:
  - `_initial_value` → `initial_value::T`
  - `_root_target` → `root_target::Union{String,Nothing}`
  - `_target` → `target::Union{String,Nothing,BaseOp}`  *(but see below — `target` is a property in Python; in Julia it's just the field, with getter/setter functions)*
  - `_auto_save` → `auto_save::Bool` (just a public field; no getter needed)
  - `_args`, `_kwargs` → `args::Vector{Any}`, `kwargs::Dict{Symbol,Any}`
- Python properties (`@property`) → Julia getter/setter **functions**, not
  syntactic. So `compartment.root` (Python) → `root(compartment)` (Julia). For
  *setter* properties (`@target.setter`) → `target!(compartment, value)`.
- Python `_setup(self, compName, path)` → Julia `setup!(c::Compartment, comp_name, path)`. The trailing `!` is convention for mutating functions.

### Class hierarchy mapping

```julia
abstract type AbstractContextAwareObject end             # context module
abstract type AbstractComponent <: AbstractContextAwareObject end
abstract type AbstractCompartmentLike end                # for both Compartment + BaseOp
```

Concrete types:

```julia
mutable struct Compartment{T} <: AbstractCompartmentLike
    initial_value::T
    name::Union{String,Nothing}
    root_target::Union{String,Nothing}
    target::Union{String,Nothing,AbstractCompartmentLike}   # str | BaseOp | None
    display_name::Union{String,Nothing}
    units::Union{String,Nothing}
    plot_method::Union{Function,Nothing}
    auto_save::Bool
end

mutable struct Component <: AbstractComponent
    name::String
    context_path::String
    args::Vector{Any}        # populated by macro/constructor wrapper (see context spec)
    kwargs::Dict{Symbol,Any}
    # user-added Compartment fields live as additional mutable struct fields in
    # user-defined subtypes <: AbstractComponent
end
```

**Important**: user-defined component types are concrete subtypes of
`AbstractComponent`, not instances. The `compartments(c)` accessor walks
`fieldnames(typeof(c))` and returns the subset whose value is `<: AbstractCompartmentLike`:

```julia
function compartments(c::AbstractComponent)
    pairs = Tuple{Symbol,AbstractCompartmentLike}[]
    for f in fieldnames(typeof(c))
        v = getfield(c, f)
        if v isa AbstractCompartmentLike
            push!(pairs, (f, v))
        end
    end
    return pairs
end
```

### Operator-injection macro

See "Metaclass behavior" above for the `@inject_compartment_ops()` macro. Define
it once and invoke at the bottom of `Compartment.jl`. `BaseOp` reuses the same
abstract supertype, so it gets the same methods for free.

### `__jax_array__` analog

For Reactant.jl, instead of `__jax_array__`, the compartment must implement
whatever Reactant uses for `Base.convert(::Type{<:TracedRArray}, ::Compartment)`
or its trace-time materialization hook. Implementation detail goes in the JIT
spec (sibling document), but the *call site* in this module is:

```julia
# Replaces Python's __jax_array__
function Reactant.materialize(c::Compartment)
    return get_value(c)
end
```

### `_to_ast` analog

In Julia, JIT happens via Reactant tracing rather than explicit AST construction.
But for the *symbolic compile path* (mirroring what `parser/utils.py` does), the
equivalent of `_to_ast` is:

```julia
function to_expr(c::Compartment, ctx::Symbol)
    if c.target isa String
        return :( $ctx[$(c.target)] )
    else  # BaseOp
        return to_expr(c.target, ctx)
    end
end
```

This produces an `Expr` that, when `eval`'d with `ctx` bound to a `Dict`, returns
the same value as `_get_value(c)`. The full compile pipeline (cross-module —
`compileObject`, `_methodWrapper`, `CompiledMethod`) is the subject of the
Phase B parser spec; this module only needs `to_expr`.

### Operator overload `>>`

Julia's `>>` is right-shift on integers; overloading it for compartments is fine
(precedent: Pipe.jl, Lazy.jl) but consider an explicit `wire!(source, dest)`
function as the canonical API and define `>>` as sugar:

```julia
function wire!(source::AbstractCompartmentLike, dest::Compartment)
    ctx = current_context(CONTEXT)
    if ctx !== nothing
        add_connection!(ctx, source, dest)
    end
    target!(dest, source)
    return dest
end

Base.:(>>)(source::AbstractCompartmentLike, dest::Compartment) = wire!(source, dest)
```

### Global state interface (referenced, not defined here)

The port writer must coordinate with the global-state spec (sibling). The
interface this module needs:

```julia
add_compartment!(::GlobalStateManager, ::Compartment)
set_state!(::GlobalStateManager, ::Dict{String,Any})         # or @kwarg form
from_global_key(::GlobalStateManager, ::String)::Union{Nothing,Any}
```

These mirror `global_state/manager.py:12-13, 79-86, 54-63`.

### `@compilable` / `@component` decorators

In Julia, both collapse to type-level traits:

```julia
abstract type AbstractCompilable end
abstract type AbstractComponent <: AbstractContextAwareObject end
# Compilable trait
is_compilable(::Type) = false
is_compilable(::Type{<:AbstractCompilable}) = true
# Or holy-trait pattern with CompilableTrait/NotCompilableTrait
```

A user's component declaration becomes:

```julia
mutable struct MyNeuronLayer <: AbstractComponent
    name::String
    context_path::String
    args::Vector{Any}
    kwargs::Dict{Symbol,Any}
    voltage::Compartment{Vector{Float32}}
    spikes::Compartment{Vector{Float32}}
end
# Marked compilable by default (since AbstractComponent <: AbstractCompilable)
```

---

## Open questions / hazards

1. **Upstream bug in `__rsub__` and other non-commutative reverse ops**
   (`compartmentMeta.py:31`, `:42-44`). The reverse-dunder mapping passes the
   *unswapped* `operator.sub`, but `_unwrap(self)` is the *receiver* (the
   right operand in the reflected call). So `5 - compartment` (which Python
   routes to `compartment.__rsub__(5)`) computes `compartment_value - 5`
   instead of `5 - compartment_value`. Same affects `__rtruediv__`,
   `__rfloordiv__`, `__rmod__`, `__rpow__`, `__rmatmul__`, `__rsub__`,
   `__rlt__/__rle__/__rgt__/__rge__`. **Port decision needed**: faithful (bug
   preserved) vs corrected. Recommend corrected + memo in CHANGELOG.

2. **`get_needed_keys` for string targets** (`compartment.py:108`):
   `set(self.target)` where `target` is a string produces a set of *individual
   characters*, not a single-element set. This is almost certainly a bug —
   nothing in the codebase consumes individual chars from this. The Julia port
   should write `Set([target])` and document the divergence.

3. **`target.setter` dead branch** (`compartment.py:167-169`): the second `if
   isinstance(value, str)` block is unreachable because the first one at `:159`
   already catches strs. The `raise ValueError` at `:170` only fires for foreign
   types because the function falls through with no `else`. Port should
   collapse to: "must be `String`, `<:BaseOp`, or `Compartment`, else error".

4. **`Component.compartments` discovery via `vars(self)`**
   (`component.py:26`): this picks up *every* attribute, including user-assigned
   non-compartment fields that happen to be compartments. The Julia equivalent
   walking `fieldnames(typeof(c))` is safer because it only sees declared
   struct fields. Behavioral parity should be fine for any non-pathological
   user code.

5. **`_setup` is called from where?** Not from inside these four files. The
   port writer must consult the **context spec** for the call site —
   `_setup(compName, path)` is invoked when a `Compartment` is bound into a
   `Component` inside a `Context` block. This is the integration point between
   this spec and the context module. Expected location: a method on `Context`
   that walks the `Component.compartments` list and calls `_setup` on each
   with `(compName=field_name, path=component.context_path + ":" + component.name)`
   or similar. **Verify against context spec; do not invent.**

6. **`__rrshift__` calls `gcm.current_context.add_connection(other, self)`**
   (`compartment.py:136`) — this method `add_connection` is on `Context`, not
   shown in these files. The connection signature `(source, dest)` is the
   convention. Coordinate with context spec.

7. **`target` rebind chases one hop** (`compartment.py:163-165`): the setter
   does `self._target = value.target`, NOT `self._target = value`. So wiring
   chains do not auto-update. If `a` is later rewired, `b` still points at the
   *old* `a.target`. Faithful translation must preserve this; port should not
   "fix" it to a back-reference.

8. **`__jax_array__` ↔ Reactant**: Reactant.jl's analog of JAX's array protocol
   is via `TracedRArray` / dispatch hooks; the exact integration point depends
   on Reactant's current API. The port writer should validate this against the
   live Reactant docs at port time and choose between (a) implement
   `Base.convert`, (b) implement Reactant-specific `materialize`, or (c) leave
   it as `get_value(c)` and require users to call it explicitly inside
   `@compile` blocks.

9. **Overlap with other modules** — flag for synthesis step:
   - `context/contextAwareObject.py` defines `to_json` and `compile` on the
     base class. These belong to the **context module spec**, not this one,
     but `Component` inherits them.
   - `parser/utils.py` defines `compilable`, `CompiledMethod`,
     `compileObject`, `_methodWrapper`, `parse_method`. These are referenced
     by `@compilable` on `Component` but their implementation belongs to the
     **parser/JIT module spec**.
   - `operations/BaseOp.py` is checked via `isinstance` at three sites
     (`compartment.py:106, 114, 159`) and `BaseOp` shares the metaclass — it
     belongs to its own **operations module spec** but the abstract
     supertype `AbstractCompartmentLike` is shared and should be defined
     *once* in a shared abstract-types module.
   - `global_state/manager.py` defines the global mutable singleton this
     module reads/writes through. It is referenced 3× in this module
     (`compartment.py:74, 93, 117`) and belongs to its own **global state
     spec**.
   - `context/context_manager.py` is used at one site (`compartment.py:135`).
     The `current_context` and `add_connection` surface belongs to the
     **context spec**.

10. **`ContextAwareObjectMeta` metaclass not read here** — the port writer
    needs to consult the context spec to learn how `_args` and `_kwargs` get
    populated on a `ContextAwareObject` instance. Without it,
    `ContextAwareObject.to_json` (used by `Component`) cannot be ported
    faithfully.

11. **Thread-safety**: nothing in these files is thread-safe (module-level
    singleton state, no locks). Julia port should preserve that initially;
    if the simulator ever needs concurrency, lock the
    `GlobalStateManager` and `ContextManager` at the singleton level. Not a
    port-time concern.
