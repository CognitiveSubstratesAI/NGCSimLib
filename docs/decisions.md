# NGCSimLib design decisions log

Cross-cutting patterns. Per-file rationale lives in code comments at the
point it's made — this file captures decisions that **span the whole
package** and that future-you (or a collaborator) needs without grep'ing
every source file.

Format: one section per decision, dated. Append as we go. No formal
"Status / Context / Consequences" template — if it's here, it's adopted;
if we change our minds, edit + re-date the section.

---

## 1. Singletons use `OncePerProcess`, not `const Ref` + `__init__`

Date: 2026-05-31

Module-level singletons (Logger's `_LoggerSlot`, GlobalState's
`GlobalStateManager`) use Julia 1.12's `OncePerProcess{T}() do … end` for
lazy, precompile-safe init. Reject `const Ref{T}()` + `__init__` because:

- stdlib streams (`stderr`) can't be captured into `const Ref` at
  precompile time — the handle is stashed in the `.ji` file and breaks on
  first load.
- `__init__` ordering across files is implicit; `OncePerProcess` is
  explicit at the call site.

When the singleton needs to be **swappable** (Logger's `init_logging`
replaces the active logger), wrap a `mutable struct` holding the
swappable field (`_LoggerSlot` pattern) and let `OncePerProcess` own the
construction of the wrapper.

Implication: `NGCSimLib.__init__()` is empty. Anything tempted to live
there should become a `OncePerProcess` or move to its consumer.

References: [src/support/Logger.jl](../src/support/Logger.jl),
[src/core/GlobalState.jl](../src/core/GlobalState.jl).

---

## 2. Multiple dispatch over `AbstractValueNode` replaces Python metaclass dunder injection

Date: 2026-05-31

Upstream `CompartmentMeta` (Python metaclass) installs `__add__`,
`__sub__`, ... on Compartment and BaseOp so `c1 + c2` returns an unwrapped
numeric value via `_unwrap`. Julia has no metaclasses — we generate three
method signatures per binary op:

- `(::AbstractValueNode, ::AbstractValueNode)`
- `(::AbstractValueNode, ::Any)`
- `(::Any, ::AbstractValueNode)`

via `for op in (:+, :-, …); @eval … end` in
[Compartment.jl](../src/core/Compartment.jl) (`_COMPARTMENT_BINARY_OPS`).

Bonus: reverse-op semantics work for free. Upstream has a known bug where
`__rsub__(self, 5)` evaluates as `_unwrap(self) - 5` (wrong order); Julia's
dispatch gets it right without special-casing.

Implication: any new `<:AbstractValueNode` subtype (future `InitOp`,
`MatMul`, etc.) inherits arithmetic — no per-type boilerplate.

---

## 3. Don't define bare `get(::CustomType)` — shadows `Base.get`

Date: 2026-05-31

Hit a regression where defining `get(c::Compartment) = get_value(c)` broke
every `get(dict, key, default)` call across the module (Priority,
Deprecators, Config, Modules, GlobalState all use `Base.get`). After
defining `get` in the NGCSimLib module namespace, those calls resolved to
the new single-arg method instead of `Base.get`.

Rule: don't define a bare `get`, `set`, `put`, `pop` etc. on a custom type
inside a module that also uses `Base` versions for Dicts/Sets. Use the
typed verb (`get_value`, `set!`) or fully qualify `Base.get(...)` at every
call site.

Implication: the upstream API spelling `comp.get()` is **not** idiomatic
Julia — use `get_value(c)` instead. Clearer + safer.

References: [src/core/Compartment.jl](../src/core/Compartment.jl) (the
comment block where the deleted `get` definition used to live).

---

## 4. Struct fields use Julia names; functions use upstream-API names

Date: 2026-05-31

When upstream's accessor name collides with a clean Julia field name, the
**function** keeps the upstream spelling and the **field** gets a different
name:

| Upstream `c.root` | Field `c.root_target` | Accessor `root(c)` |

Users write `root(c)` (matches `comp.root` in upstream docs) while the
field name stays descriptive and avoids shadowing other module-level
bindings.

Subtypes of `AbstractCompartmentLike` that need to be registered via
`add_compartment!` must expose a `root_target::String` field — this is the
protocol contract (`GlobalState.add_compartment!` reads it directly).

---

## 5. Fix upstream bugs; document; don't port faithfully

Date: 2026-05-31

When a per-module spec under [docs/specs/](specs/) flags an upstream bug in
"Open questions / hazards," we fix it in the port and document the
divergence in the relevant file's preamble. Shipped so far:

- `__rsub__` reverse-op order bug → fixed automatically by Julia dispatch
  (`Compartment.jl`).
- `Compartment.get_needed_keys` `set(self.target)` → single-char set bug
  → fixed to `Set([target])` (`Compartment.jl`).
- `Guides.__monitoring` trailing-comma 1-tuple bug → fixed by rendering
  the output section as intended (`Help.jl`).
- `BaseOp.get_needed_keys` non-mutating `keys.union(...)` bug → fixed to
  `union!` (`Operations.jl`).

Counter-example (port verbatim with hazard note): `load_attribute`
first-char-uppercase-only rule (`Modules.jl`) — *not* a bug per the spec,
an intentional camelCase convention.

Implication: the port is **not faithful**. It is **upstream-but-corrected**.
End-user behavior diverges from Python ngcsimlib in documented ways.

---

## 6. `ReentrantLock` + `@lock` for protecting mutable collections

Date: 2026-05-31

Julia has no GIL. Anywhere a mutable Dict / Vector / Set is exposed to
user code that might be called from multiple threads, wrap mutations in
`@lock obj.lock begin … end` using a `ReentrantLock` field on the owning
struct.

Use `OncePerProcess` for the singleton; the lock lives **inside** the
singleton's struct, not as a separate global.

Don't reach for `@atomic` / `AtomicMemory` — those help only for primitive
single-word values. Dict mutations need a lock regardless. Verified by
the 1000-task concurrent `add_key!` smoke test in
[test/test_globalstate.jl](../test/test_globalstate.jl).

---

## 7. Skip Aqua during Phase A scaffold; re-enable post-Phase-A

Date: 2026-05-31

`Aqua.jl` is in `[extras]` and the `[targets]` test row, but `runtests.jl`
keeps the `@testset "Aqua quality checks"` commented out. Reason: during
scaffold (lots of stub files, ambiguous methods, incomplete exports),
Aqua fires every check and drowns the signal-to-noise ratio.

Re-enable when:
1. All Phase A files have real implementations (not stubs).
2. Test suite is otherwise green.

---

## 8. JuliaSymbolics — defer evaluation to NGCLearn, not NGCSimLib

Date: 2026-05-31 (forward-looking)

[JuliaSymbolics](https://juliasymbolics.org/) (Symbolics.jl + ModelingToolkit.jl
+ SymbolicRegression.jl etc.) is the Julia ecosystem for symbolic
computation — algebraic variables, symbolic differentiation, equation
systems, ODE auto-discretization, codegen.

**Verdict for NGCSimLib (this package):** not relevant. Our Parser does
**structural Expr rewriting** at the syntax-tree level (`c.voltage` →
`ctx["net:layer:voltage"]`, `set!(c.field, v)` → `ctx[key] = v`) — that's
source-to-source transformation, not algebraic manipulation. Compartments
hold concrete arrays, not symbolic scalars. Plugging Symbolics in here
would be a square peg in a round hole.

**Verdict for NGCLearn (next package up the stack):** worth a pilot.
Likely-good fits:

1. **ODE-defined neuron models** — LIF / exp-IF / AdEx / etc. are all
   `dv/dt = …` ODEs. `ModelingToolkit.jl` lets you write the ODE
   symbolically and auto-derive the discrete update + Jacobian, much
   cleaner than the hand-coded discretization NACLab Python uses.
2. **Symbolic gradient comparators** — for verifying that Hebbian / local
   update rules match the published papers. Symbolic ∂L/∂w gives a
   ground-truth check against the Enzyme-generated gradients.
3. **LaTeX-rendered equations in Documenter pages** — write the membrane
   equation once symbolically; render to LaTeX for docs, lower to Julia
   for Reactant tracing.

**Compositional, not competitive with Reactant.** Symbolics / MTK sits
*above* Reactant: write a model symbolically with MTK, lower it to a
plain Julia function, then Reactant traces that function. Backend stays
Reactant + Enzyme.

**Action:** when porting NGCLearn, pilot ModelingToolkit on one neuron
type (likely LIF), compare against a hand-coded version on LOC +
verifiability + perf. If it pays off, adopt for the whole component zoo.
If not, hand-code stays.

References: none yet — this is forward-looking. Re-date and update when
the NGCLearn pilot lands.

---

## Decision update policy

- Update this file when a decision affects **more than one file** OR
  **would surprise a reader who didn't write the original code**.
- Per-file decisions stay in code comments at point-of-decision.
- No "Status: Proposed" headers — if it's here, it's adopted. If we change
  our minds, edit the relevant section and re-date the change.
- Append-only? No — *correct in place* when the decision changes; don't
  leave stale advice next to current advice.
