using Test
using NGCSimLib

@testset "NGCSimLib" begin

    @testset "Module loads + version constant" begin
        @test isdefined(NGCSimLib, :NGCSIMLIB_VERSION)
        @test NGCSimLib.NGCSIMLIB_VERSION isa VersionNumber
        @test NGCSimLib.NGCSIMLIB_VERSION >= v"0.1.0"
    end

    @testset "Abstract type hierarchy is in place" begin
        # Per docs/NGCSimLib_design.md §3
        @test isdefined(NGCSimLib, :AbstractValueNode)
        @test isdefined(NGCSimLib, :AbstractCompartmentLike)
        @test isdefined(NGCSimLib, :AbstractOp)
        @test isdefined(NGCSimLib, :AbstractComponent)
        @test isdefined(NGCSimLib, :AbstractContext)
        @test isdefined(NGCSimLib, :AbstractProcess)

        # Hierarchy relationships
        @test NGCSimLib.AbstractCompartmentLike <: NGCSimLib.AbstractValueNode
        @test NGCSimLib.AbstractOp <: NGCSimLib.AbstractValueNode
    end

    @testset "Logger — support layer" begin
        include("test_logger.jl")
    end

    @testset "Priority — support layer" begin
        include("test_priority.jl")
    end

    @testset "Deprecators — support layer" begin
        include("test_deprecators.jl")
    end

    @testset "Config — support layer" begin
        include("test_config.jl")
    end

    @testset "IO — support layer" begin
        include("test_io.jl")
    end

    @testset "Modules — support layer" begin
        include("test_modules.jl")
    end

    @testset "Help — support layer" begin
        include("test_help.jl")
    end

    @testset "GlobalState — core data plane" begin
        include("test_globalstate.jl")
    end

    @testset "Compartment — core" begin
        include("test_compartment.jl")
    end

    @testset "Operations — core" begin
        include("test_operations.jl")
    end

    @testset "Component — core" begin
        include("test_component.jl")
    end

    @testset "Context + ContextManager + ContextAware — core" begin
        include("test_context.jl")
    end

    @testset "Parser + ContextTransformer + KwargsTransformer" begin
        include("test_parser.jl")
    end

    @testset "Process (BaseProcess + MethodProcess + JointProcess)" begin
        include("test_process.jl")
    end

    @testset "Reactant integration (Process JIT)" begin
        include("test_reactant_integration.jl")
    end

    # Aqua quality checks: skipped during Phase A scaffold; re-enable once
    # actual code lands (see test/aqua.jl). Requires Pkg.test() activation
    # because Aqua is in [extras] / [targets].
    #
    # @testset "Aqua quality checks" begin
    #     include("aqua.jl")
    # end

end
