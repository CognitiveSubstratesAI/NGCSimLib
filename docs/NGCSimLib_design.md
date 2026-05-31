# NGCSimLib — Design (synthesized from 6 Phase-A specs)

**Date**: 2026-05-31
**Source**: synthesized from `docs/specs/01_*.md` through `06_*.md` (4,638 lines of
per-module spec). The per-module specs are the authoritative line-by-line
mapping; this document is the cohesive design that ports across all six
modules and resolves cross-module decisions.
**Status**: design — package scaffolding next.

This is **Phase A of the layered port** per `project_naclab_fabricpc_julia_port_plan`:

```
Layer 0 (this)  NGCSimLib      2.9k LOC, substrate
Layer 1         NGCLearn.jl    18.7k LOC, model families (next phase)
Layer 2         FabricPC.jl    9.5k LOC, PC graph framework
Layer 3         ngc-museum     acceptance suite (not ported)
```

---

## 1. What ngcsimlib actually IS (cross-module consensus)

After reading all six modules, the picture is clearer than the project README suggests.

ngcsimlib is **a domain-specific embedded language for biophysical simulation
graphs**, implemented in Python via:

1. **Class-level decorators** (`@context_aware`, `@compilable`, `@priority`) that
   inject behavior at definition time.
2. **A metaclass-based registry** (`ContextAwareObjectMeta`, `CompartmentMeta`)
   that auto-runs setup on instance construction.
3. **A module-level singleton** (`global_state_manager`) holding the entire
   compartment state keyed by `"context_path:local_key"`.
4. **An AST-rewriter "JIT"** (`@compilable` + parser/contextTransformer) that
   transforms user methods into pure `(ctx, **kwargs) -> ctx` functions, then
   compiles them with stdlib `compile()` + `exec()`. **This is not JAX `jit`.**
   The resulting pure functions are then JIT-compatible if user code is.

The Julia port keeps all four mechanisms, but each maps to a more idiomatic
construct: macros for (1) and (2), `const Ref` + `ReentrantLock` for (3),
and `Expr`-walking macros for (4).

---

## 2. Package structure (proposed)

```
NGCSimLib/
├── Project.toml
├── README.md
├── src/
│   ├── NGCSimLib.jl                # top-level module + public exports
│   ├── support/
│   │   ├── Logger.jl              # error()/critical() raise; 6 levels + custom-level dispatch
│   │   ├── Config.jl              # _GlobalConfig analog; JSON3.jl
│   │   ├── Priority.jl            # IdDict-backed @priority macro
│   │   ├── Modules.jl             # load_attribute (camelCase resolver) + dynamic type registry
│   │   ├── Help.jl                # Guides + docstring introspection
│   │   ├── IO.jl                  # JSON3 round-trip helpers
│   │   └── Deprecators.jl         # @deprecated + @deprecate_args
│   ├── core/
│   │   ├── GlobalState.jl         # GLOBAL_STATE + ReentrantLock + check_key/get/set
│   │   ├── AbstractTypes.jl       # AbstractValueNode, AbstractCompartmentLike,
│   │   │                          # AbstractComponent, AbstractContext, AbstractOp
│   │   ├── ContextAware.jl        # @context_aware macro + base mixin
│   │   ├── Compartment.jl         # Compartment{T} struct + arithmetic injection macro
│   │   ├── Component.jl           # AbstractComponent + _setup! protocol
│   │   ├── Context.jl             # Context struct + path/scope/objects map + recompile!
│   │   ├── ContextManager.jl      # ContextManager singleton + with_context do-block
│   │   └── Operations.jl          # BaseOp / Summation / Product
│   ├── parser/
│   │   ├── Parser.jl              # Expr-walking infrastructure
│   │   ├── ContextTransformer.jl  # the big rewriter: self.x → ctx[path]
│   │   └── KwargsTransformer.jl   # kwargs["K"] → K
│   └── process/
│       ├── BaseProcess.jl         # run!, compile!, pack_keywords, watch
│       ├── MethodProcess.jl       # single-method process
│       └── JointProcess.jl        # multi-method composition
├── docs/
│   ├── NGCSimLib_design.md        # (this file)
│   └── specs/                     # the 6 per-module specs from Phase A intake
└── test/
    └── runtests.jl
```

**File count budget**: ~22 source files for ~2,875 upstream LOC.

---

## 3. Core type hierarchy

The single most load-bearing decision is the abstract type tree. All 6 specs
flagged the need for a shared supertype between `Compartment` and `BaseOp`
(both share `CompartmentMeta` in Python — both auto-inject `+`/`*`/`>>`).

```julia
# core/AbstractTypes.jl

# Anything that can appear as a node in a compartment-arithmetic expression
# AND be lowered to an AST fragment by the parser.
abstract type AbstractValueNode end

# A piece of mutable state owned by a Component, with a global registry key
abstract type AbstractCompartmentLike <: AbstractValueNode end

# Pure-computation node (no own state, sources from other AbstractValueNodes)
abstract type AbstractOp <: AbstractValueNode end

# A user-defined biophysical unit; contains Compartments + @compilable methods
abstract type AbstractComponent end

# A named scope holding Components + Processes
abstract type AbstractContext end

# A scheduled callable produced from a Component's @compilable method
abstract type AbstractProcess end
```

**Why this shape:**
- `AbstractValueNode` is the type the arithmetic ops dispatch on. `c1 + c2`
  works whether `c1` is a `Compartment` or a `Summation` op.
- `AbstractCompartmentLike` carves out the "has state, needs registration" subset.
- `AbstractOp` is the "no state, pure-function" subset.
- `AbstractComponent` is not a `ValueNode` — components OWN compartments, they
  don't *act as* values themselves.
- `AbstractContext` and `AbstractProcess` are top-level container types.

**Bug-fix decision (from specs 01/05)**: upstream's `Compartment.get_needed_keys`
returns `set(self.target)` which produces a set of characters. **We will fix
this in the Julia port** rather than port the bug verbatim — characters-as-set
has no defensible semantic. Same for the three `BaseOp` bugs (spec 05). All
fixes get documented as `BUG-PORTED-FIXED` in the changelog so the divergence
from Python upstream is explicit.

---

## 4. Macro contract (replaces Python metaclass + decorators)

### `@context_aware`

Replaces `ContextAwareObjectMeta`. Emits:
- The struct
- An outer constructor that does: push context path → init fields → call `_setup!`
  on every contained Compartment → pop context path → register in current Context.

```julia
@context_aware mutable struct MyComponent <: AbstractComponent
    z::Compartment{Float32}
    activation_fn::Function
end
```

This expands to a struct definition plus a `MyComponent(args...; name::AbstractString, kwargs...)` outer constructor wiring the registration.

### `@compilable`

Replaces `@compilable` decorator from upstream. Eliminates the
`inspect.getsource` round-trip — Julia exposes the `Expr` to macros directly,
so we capture it at definition time:

```julia
@context_aware mutable struct MyNeuron <: AbstractComponent
    v::Compartment{Float32}
    spike::Compartment{Float32}
end

@compilable function advance!(self::MyNeuron, ctx; dt)
    self.v = self.v + dt * (-self.v / 10.0)
    self.spike = self.v > 1.0 ? 1.0 : 0.0
    ctx
end
```

The macro stores the original `Expr` in a per-type registry. Later
`compile_object!(obj)` walks the registry, runs `ContextTransformer` over each
stored `Expr`, and `eval`s the result into a fresh `Module`. The resulting
function has signature `(ctx::NamedTuple, kwargs...) -> ctx`.

### `@priority`

Replaces the `priority` decorator factory. Maintains an `IdDict{Function, Int}`
registry. Higher integer = sooner in compile order.

### `@deprecated` / `@deprecate_args`

Wrap upstream `deprecators.py` — Julia's stdlib `@deprecate` is the obvious
choice; we use it.

---

## 5. Global state (singletons)

Three module-level singletons in upstream → three Julia equivalents:

| Upstream | Julia |
|---|---|
| `global_state_manager` (dict, no locking) | `const GLOBAL_STATE = Ref(GlobalStateData())` + `const STATE_LOCK = ReentrantLock()`. All public mutators take the lock. |
| `_GlobalConfig` (JSON-backed) | `const CONFIG = Ref(NamedTuple())`. `configure(; kwargs...)` updates atomically. |
| `_ngclogger` + `_mapped_calls` | Use stdlib `Logging` + a `const CUSTOM_LEVELS = Dict{Symbol, LogLevel}()`. |

**Reasoning**: upstream's lack of locking is a real bug — flagged in spec 06.
Julia idiom is `ReentrantLock` for shared mutable state. The lock is acquired
in every `get!` / `set!` operation; cost is negligible for typical sim
workloads.

---

## 6. Context manager + scope

The trickiest port (spec 02). Three interlocking pieces:

```julia
const GLOBAL_CONTEXT_MANAGER = Ref{ContextManager}()

function __init__()
    GLOBAL_CONTEXT_MANAGER[] = ContextManager()
end

# usage:
ctx = Context("my_model")
with_context(ctx) do
    neuron = MyNeuron(name="n1")
    syn    = MySynapse(name="s1")
    neuron.v >> syn.input
end
```

`with_context` does push/init/(user-code)/pop with `try/finally` (we diverge
from upstream which lacks `try/finally` — spec 02 flagged this as a real bug
that leaves the manager corrupt on exception).

`Context("my_model")` is a get-or-create singleton keyed by path. Two calls
to `Context("my_model")` return the same object (consistent with upstream's
`__new__` override).

---

## 7. The compilation pipeline (Process)

The single most important runtime path:

```
User code:
  @compilable function advance!(self, ctx; dt) ...end
       │ macro captures Expr at def-time
       ▼
  per-type @compilable registry stores raw Expr
       │ Component constructed inside `with_context(ctx) do ... end`
       │ → registered in Context.objects[name]
       ▼
  compile_object!(component)
       │ walks each @compilable Expr through ContextTransformer:
       │   self.x         → ctx[Symbol("path:to:x")]
       │   self.x = v     → ctx = merge(ctx, (Symbol("path:to:x") => v,))
       │   self.x.get()   → same as self.x
       │   self.x.set(v)  → same as self.x = v
       │   sub.method(..) → grafted compiled AST (auxiliary closure)
       ▼
  eval the rewritten Expr → pure function (ctx::NamedTuple, kwargs...) → ctx
       │ stored in component.compiled[:advance!]
       ▼
  Process wraps one or more compiled methods + watches:
       │ MethodProcess  = call one compiled method per tick
       │ JointProcess   = concatenate several into one function body
       ▼
  Reactant.@compile (or Enzyme.gradient) applied to the resulting pure function
       │ → traced once, compiled to StableHLO/XLA, called repeatedly
       ▼
  run!(process, kwargs...) advances state
```

**The Reactant integration point is at the END of the pipeline**, after AST
rewriting + `eval`. We do NOT try to apply Reactant inside the AST
transformer — that would require Reactant to understand `self.x` references,
which it doesn't. The clean separation: ngcsimlib produces pure `(ctx, kw) →
ctx` functions; Reactant traces those, Enzyme differentiates them.

---

## 8. Operations (the smallest module, the load-bearing call)

Per spec 05, `BaseOp` shares `CompartmentMeta` with `Compartment` → both must
share `AbstractValueNode` supertype (per §3 above).

```julia
abstract type AbstractOp <: AbstractValueNode end

struct Summation{T} <: AbstractOp
    operands::Vector{AbstractValueNode}   # each must implement get_value + to_expr
end

struct Product{T} <: AbstractOp
    operands::Vector{AbstractValueNode}
end

# Eager evaluation (used by run! when ops are nested in expressions)
get_value(op::Summation) = sum(get_value, op.operands)
get_value(op::Product)   = prod(get_value, op.operands)

# AST lowering (used by ContextTransformer)
to_expr(op::Summation, ctx_sym) =
    Expr(:call, :+, [to_expr(o, ctx_sym) for o in op.operands]...)
to_expr(op::Product,   ctx_sym) =
    Expr(:call, :*, [to_expr(o, ctx_sym) for o in op.operands]...)
```

The `to_expr` method is the cross-module contract that `ContextTransformer`
relies on (spec 04). Every `AbstractValueNode` must implement it.

---

## 9. Public API (top-level `NGCSimLib` exports)

Mirroring upstream's `ngcsimlib/__init__.py` (spec 06):

```julia
module NGCSimLib

# Core abstract types
export AbstractValueNode, AbstractCompartmentLike, AbstractOp,
       AbstractComponent, AbstractContext, AbstractProcess

# Macros
export @context_aware, @compilable, @priority, @deprecated

# Types
export Compartment, Context, ContextManager
export Summation, Product

# Process types
export MethodProcess, JointProcess

# State + helpers
export with_context, configure, get_config, run!, compile_object!

# Logging
export ngc_log, ngc_warn, ngc_error, ngc_critical

# Versioning
export NGCSIMLIB_VERSION
const NGCSIMLIB_VERSION = v"0.1.0"

end
```

---

## 10. Compute-backend integration

Per the locked plan: **Reactant.jl + Enzyme.jl**.

**Reactant** = `jax.jit` analog. Used at the `run!(process)` level to compile
the assembled pure function to StableHLO.

**Enzyme** = `jax.grad` analog. Used by FabricPC.jl (Layer 2) to differentiate
predictive-coding loss with respect to compartment values. NGCSimLib
itself does NOT call Enzyme — it just produces functions that are
Enzyme-differentiable.

**Key constraint for Reactant compatibility**: the compiled `(ctx, kw) → ctx`
function must NOT have data-dependent control flow. Spec 05 verified that the
two upstream ops (Summation, Product) are safe — pure broadcasts/reductions.
Spec 04 noted the ContextTransformer does parse-time `if`-branch elimination,
which makes the output Reactant-clean by construction.

---

## 11. Upstream bug catalog (port-vs-fix decisions)

15+ upstream bugs surfaced across the 6 specs. Decisions:

| Bug | Location | Decision | Why |
|---|---|---|---|
| `Compartment.get_needed_keys` returns set of chars | spec 01, `compartment.py:108` | **FIX** | No defensible semantic |
| `BaseOp.get_needed_keys` non-mutating `keys.union(...)` discards result | spec 05, `BaseOp.py:66-73` | **FIX** | Same |
| `__rsub__`/`__rtruediv__` swap operand order | spec 01, `compartmentMeta.py:42-44` | **FIX** | Math correctness |
| `target.setter` unreachable `isinstance(value, str)` branch | spec 01, `compartment.py:167-169` | **PORT-VERBATIM** | Latent, may be intentional safety net |
| `Context.registerObj` keys by object identity not name | spec 02, `context.py:148` | **FIX** | Real bug — duplicate names go undetected |
| `Context.__exit__` runs recompile() outside try/finally | spec 02, `context.py:70-73` | **FIX** | Corrupts manager on exception |
| `step_to` returns True regardless of `exists()` | spec 02, `context_manager.py:91` | **FIX** | API contract violation |
| `BaseProcess._parse` raises `NotImplemented` constant | spec 03, `methodProcess.py` | **FIX** | Should be `NotImplementedError` analog |
| `subAst.body[0].body[:-1]` mutates in place | spec 04, `contextTransformer.py:116` | **FIX** | Deep-copy before mutate |
| Stray `print(ast.dump(node))` debug | spec 04, `kwargsTransformer.py:21` | **FIX** | Obvious leftover |
| `compileObject` iterates `dir(obj)` alphabetically not priority | spec 04, parser/utils | **FIX** | Documented contract violation |
| Logger `error()` raises (control flow not log) | spec 06 | **PRESERVE-WITH-DOC** | Likely intentional API. Document loudly. |
| `priority` decorator-not-enum naming | spec 06 | **PRESERVE-WITH-DOC** | Naming is awkward but functional |
| Help's `__monitoring` trailing-comma 1-tuple | spec 06 | **FIX** | Trivially incorrect |
| No locking on global_state_manager | spec 06 | **FIX** | Real concurrency hazard |

**Convention**: every FIX gets a code comment `# UPSTREAM-FIX 2026-05-31: <one
line describing what was wrong and the spec reference>`, and the file
`docs/UPSTREAM_DIVERGENCE.md` accumulates the full list with rationale.

---

## 12. Naming conventions

Per the 6 specs' consensus (and Julia idiom):

| Python | Julia |
|---|---|
| `_foo` (private) | `foo` (no leading underscore — Julia exports are explicit) |
| `Foo._setup(self, ...)` | `setup!(foo, ...)` |
| `foo.do_thing()` | `do_thing(foo)` |
| `@property` getter | bare function: `temperature(neuron)` |
| `@property` setter | mutating function: `set_temperature!(neuron, v)` |
| `__rshift__` / `>>` | `Base.:(>>)(a::Compartment, b::Compartment) = connect!(a, b)` |
| `__add__` / `__mul__` | `Base.:+`, `Base.:*` |
| `Context("foo")` (singleton via `__new__`) | `context(name::String)` factory function that checks the registry |

---

## 13. Module loading order

Critical for the package to compile:

```
1. support/Logger.jl, support/Priority.jl, support/Deprecators.jl
   (no internal deps)
2. support/Config.jl, support/IO.jl, support/Modules.jl, support/Help.jl
   (depend on Logger)
3. core/AbstractTypes.jl
   (no internal deps; defines all abstract types)
4. core/GlobalState.jl
   (depends on AbstractTypes for the value-store key types)
5. core/Compartment.jl, core/Operations.jl
   (depend on AbstractTypes + GlobalState)
6. core/Component.jl
   (depends on Compartment)
7. core/ContextAware.jl
   (depends on Component + Compartment + AbstractTypes — defines the macros)
8. core/Context.jl, core/ContextManager.jl
   (depend on everything above)
9. parser/Parser.jl, parser/ContextTransformer.jl, parser/KwargsTransformer.jl
   (depend on Component + Compartment + Operations — implement to_expr trait)
10. process/BaseProcess.jl, process/MethodProcess.jl, process/JointProcess.jl
    (depend on Parser + Context)
11. NGCSimLib
    (top-level module, includes all + exports)
```

---

## 14. Open questions (for the next session, not blocking scaffolding)

1. **Reactant `@compile` vs `@jit`** — spec 03 recommends `@compile`; needs
   verification against the actual Reactant.jl API at scaffold time.
2. **`importlib` analog** for dynamic class loading — spec 02 recommends an
   explicit `const TYPE_REGISTRY = Dict{String,Type}()` populated by each
   `@context_aware` macro call. Confirm during Component scaffolding.
3. **`@jax_array__` → Reactant mapping** — spec 01 flagged 3 options;
   decision deferred to Phase B when an actual JAX-typed test surfaces.
4. **`ScopedValues` vs `const Ref`** — Julia 1.11+ has `ScopedValues` for
   task-local state. Could replace `with_context` push/pop with cleaner
   scoping. Use `const Ref` for now (Julia 1.12 supports both); revisit.

---

## 15. Phase A acceptance criteria (from the parent plan)

Before claiming Phase A done:

1. `using NGCSimLib` works without errors
2. Define a minimal Component with a single Compartment and a `@compilable`
   method
3. Construct it inside a `with_context(ctx) do ... end`
4. `compile_object!` produces a callable
5. The callable runs and updates global state correctly
6. Round-trip a Context through `save_context(ctx, path)` /
   `load_context(path)` and verify state matches
7. Reproduce ONE ngc-museum exhibit (`pc_discrim` is the canonical smoke
   test per the plan)

These are END acceptance — scaffolding only needs to satisfy (1) and lay the
foundation for (2)-(7).

---

## 16. Next action

Scaffold `Project.toml`, `src/NGCSimLib.jl`, and the file skeleton in §2.
Implement support/ and core/AbstractTypes.jl first (they have no internal
deps and unblock everything else). Get `using NGCSimLib` to load cleanly
before moving on.
