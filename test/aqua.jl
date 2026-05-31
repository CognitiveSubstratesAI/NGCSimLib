using Aqua
using NGCSimLib

# Quality checks per https://github.com/JuliaTesting/Aqua.jl.
# Some checks are relaxed during early scaffolding; tighten as the package matures.

@testset "Aqua: undefined exports" begin
    Aqua.test_undefined_exports(NGCSimLib)
end

@testset "Aqua: project formatting" begin
    Aqua.test_project_extras(NGCSimLib)
end

@testset "Aqua: stale dependencies" begin
    Aqua.test_stale_deps(NGCSimLib)
end

@testset "Aqua: deps compat" begin
    Aqua.test_deps_compat(NGCSimLib)
end

# Skipped during scaffold phase (re-enable once real code lands):
# - Aqua.test_ambiguities (will fire on stubs with no methods yet)
# - Aqua.test_piracy (no methods to pirate yet)
# - Aqua.test_unbound_args (no type-parameter methods yet)
