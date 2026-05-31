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
User code (@compilable function ... end)
  │ macro captures Expr at definition site
  ▼
Per-type @compilable registry
  │ Component constructed in `with_context(ctx) do ... end`
  ▼
compile_object!(component) — walks Expr through ContextTransformer:
  self.x         → ctx[Symbol("path:to:x")]
  self.x = v     → merge ctx with new value
  sub.method(..) → graft compiled AST
  ▼
eval → pure function (ctx::NamedTuple, kwargs...) → ctx
  ▼
Process wraps one or more compiled methods
  ▼
Reactant.@compile → StableHLO/XLA
  ▼
run!(process, kwargs...)
```

The Reactant integration is at the END — after AST rewriting + `eval`. The
parser produces pure functions; Reactant traces those; Enzyme differentiates
them.
