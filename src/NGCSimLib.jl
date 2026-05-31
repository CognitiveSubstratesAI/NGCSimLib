# NGCSimLib — Julia port of NACLab's ngcsimlib (https://github.com/NACLab/ngc-sim-lib).
#
# This is Layer 0 of the NGC stack:
#   Layer 0 (this)  NGCSimLib      substrate — Component / Compartment / Context / Process
#   Layer 1         NGCLearn.jl    biophysical component zoo (next phase)
#   Layer 2         FabricPC.jl    predictive-coding graph framework
#
# See `docs/NGCSimLib_design.md` for the architecture + `docs/specs/*.md` for the
# per-module ports from upstream Python.

module NGCSimLib

# ── Public surface (mirrors ngcsimlib/__init__.py) ─────────────────────────────

const NGCSIMLIB_VERSION = v"0.1.0"

# Module layout follows docs/NGCSimLib_design.md §2 + §13 (load order).
# Each file is loaded from least-dependencies to most.

# Support layer (no internal deps) — load first
include("support/Logger.jl")
include("support/Priority.jl")
include("support/Deprecators.jl")
include("support/Config.jl")
include("support/IO.jl")
include("support/Modules.jl")
include("support/Help.jl")

# Core types — abstract type hierarchy defined here; nothing else loads before it
include("core/AbstractTypes.jl")

# Global mutable state (singletons with locks)
include("core/GlobalState.jl")

# Concrete leaf types
include("core/Compartment.jl")
include("core/Operations.jl")

# Component (depends on Compartment)
include("core/Component.jl")

# Context manager singleton — loads FIRST among the context group so that
# Context.jl and ContextAware.jl can use step!/current_path/etc.
include("core/ContextManager.jl")

# Context-aware macro infrastructure
include("core/ContextAware.jl")

# Context type (depends on the manager + everything above)
include("core/Context.jl")

# Parser (AST rewriter — depends on Component + Compartment + Operations).
# Transformers MUST load before Parser, which uses ContextTransformer +
# transform_kwargs.
include("parser/ContextTransformer.jl")
include("parser/KwargsTransformer.jl")
include("parser/Parser.jl")

# Process (depends on Parser + Context)
include("process/BaseProcess.jl")
include("process/MethodProcess.jl")
include("process/JointProcess.jl")

# ── Exports ────────────────────────────────────────────────────────────────────

# Versioning
export NGCSIMLIB_VERSION

# (Per-module exports are added incrementally as each file gets its real
# implementation; for now only NGCSIMLIB_VERSION is guaranteed.)

# ── Runtime initialization (post-precompile) ──────────────────────────────────
#
# Intentionally absent. Every module-level singleton that needs deferred
# construction (Logger, GlobalState) uses `OncePerProcess` from Base, which
# handles precompile-safe lazy init on first access — no explicit `__init__`
# hook required.

end # module NGCSimLib
