# AbstractTypes.jl — the shared abstract type hierarchy.
# See docs/NGCSimLib_design.md §3.

"Anything that can appear as a node in a compartment-arithmetic expression."
abstract type AbstractValueNode end

"A piece of mutable state owned by a Component, with a global registry key."
abstract type AbstractCompartmentLike <: AbstractValueNode end

"Pure-computation node (no own state, sources from other AbstractValueNodes)."
abstract type AbstractOp <: AbstractValueNode end

"A user-defined biophysical unit; contains Compartments + @compilable methods."
abstract type AbstractComponent end

"A named scope holding Components + Processes."
abstract type AbstractContext end

"A scheduled callable produced from a Component's @compilable method."
abstract type AbstractProcess end
