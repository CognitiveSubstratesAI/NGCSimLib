# test_priority.jl — coverage for src/support/Priority.jl

@testset "priority! registers and is read by get_priority" begin
    f = (x) -> x + 1
    @test NGCSimLib.get_priority(f) == 0         # unregistered default
    @test !NGCSimLib.has_priority(f)
    @test NGCSimLib.priority!(f, 5) === f          # returns fn unchanged
    @test NGCSimLib.get_priority(f) == 5
    @test NGCSimLib.has_priority(f)
end

@testset "explicit-zero distinguishable from unregistered" begin
    f = (x) -> x
    g = (x) -> x
    NGCSimLib.priority!(f, 0)
    @test NGCSimLib.get_priority(f) == 0
    @test NGCSimLib.has_priority(f)
    @test NGCSimLib.get_priority(g) == 0
    @test !NGCSimLib.has_priority(g)
end

@testset "registry handles named functions and callable structs" begin
    function _named_fn(x)
        ;
        x;
    end
    NGCSimLib.priority!(_named_fn, 7)
    @test NGCSimLib.get_priority(_named_fn) == 7

    # callable struct
    struct _CallableP
        ;
        v::Int;
    end
    (c::_CallableP)(x) = c.v + x
    inst = _CallableP(3)
    NGCSimLib.priority!(inst, 42)
    @test NGCSimLib.get_priority(inst) == 42
end
