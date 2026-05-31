# Architecture

See [`NGCSimLib_design.md`](https://github.com/CognitiveSubstratesAI/NGCSimLib/blob/main/docs/NGCSimLib_design.md)
for the full design document. The per-module ports from upstream Python are
in [`docs/specs/`](https://github.com/CognitiveSubstratesAI/NGCSimLib/tree/main/docs/specs).

## Abstract type hierarchy

```
AbstractValueNode
├── AbstractCompartmentLike
│   └── Compartment{T}
└── AbstractOp
    ├── Summation
    └── Product

AbstractComponent       # owns Compartments + @compilable methods
AbstractContext         # named scope holding Components
AbstractProcess         # scheduled callable from @compilable methods
```

## Compilation pipeline

```
User code (@compilable function advance!(c, dt) ... end)
  │ macro captures (args, body) Expr at definition site
  ▼
Per-type @compilable registry, keyed (Type, :symbol)
  │ Component constructed inside `Context("net") do ctx ... end`
  │ post_init!(c) wires Compartment fields + registers in Context
  ▼
parse_method(c, :advance!) walks the body Expr through ContextTransformer:
  c.voltage                  → ctx["net:layer1:voltage"]
  set!(c.voltage, v)         → ctx["net:layer1:voltage"] = v
  get_value(c.voltage)       → ctx["net:layer1:voltage"]
  return c                   → return ctx
  + KwargsTransformer rewrites `kwargs[:lr]` → `lr` (bare local)
  + every positional arg after the receiver is promoted to required kwarg
  ▼
Core.eval(Main, ...) — pure function _pure_<Type>_<method>(ctx; kwargs...)
                                                                  → ctx
  ▼
Process.compile_process! glues N rewritten functions into a sequential
runner closure, wrapped in CompiledRunner. Eager-JIT works here already.
  ▼
Process.compile_with_reactant!(p, sample_ctx, sample_loop_args) (opt-in):
  Reactant.@compile traces the eager runner once with sample shapes.
  Returns a Reactant.Compiler.Thunk wrapped in CompiledRunner — same
  signature, same numeric output, XLA-backed.
  ▼
run(p; kwargs...) — works identically against either CompiledRunner
```

The Reactant integration is at the END — after Expr rewriting + Core.eval.
The Parser produces pure Dict-ctx functions; Reactant traces those;
Enzyme differentiates them. See [`docs/decisions.md`](https://github.com/CognitiveSubstratesAI/NGCSimLib/blob/main/docs/decisions.md) §9 for the
empirical validation that the Parser's Dict-ctx form is Reactant-traceable
without modification.
