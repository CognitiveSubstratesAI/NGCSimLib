# test_globalstate.jl — coverage for src/core/GlobalState.jl

@testset "make_key composes upstream-compatible string" begin
    @test NGCSimLib.make_key("net.layer1.W", "value") == "net.layer1.W:value"
    @test NGCSimLib.make_key("a", "b") == "a:b"
end

@testset "global_state_manager() is a one-per-process singleton" begin
    a = NGCSimLib.global_state_manager()
    b = NGCSimLib.global_state_manager()
    @test a === b
    @test a isa NGCSimLib.GlobalStateManager
end

@testset "add_key! / from_global_key / from_local_key" begin
    NGCSimLib.reset_global_state!()
    @test NGCSimLib.check_key("net:w") == false
    @test NGCSimLib.from_global_key("net:w") === nothing

    NGCSimLib.add_key!("net", "w", [1.0, 2.0, 3.0])
    @test NGCSimLib.check_key("net:w") == true
    @test NGCSimLib.from_global_key("net:w") == [1.0, 2.0, 3.0]
    @test NGCSimLib.from_local_key("net", "w") == [1.0, 2.0, 3.0]
    @test NGCSimLib.from_local_key("absent", "key") === nothing
end

@testset "set_state! merges (does NOT replace)" begin
    NGCSimLib.reset_global_state!()
    NGCSimLib.add_key!("a", "k1", 1)
    NGCSimLib.add_key!("a", "k2", 2)
    # set_state! adds new keys + overwrites overlapping ones, preserves the rest
    NGCSimLib.set_state!(Dict("a:k2" => 99, "a:k3" => 3))
    @test NGCSimLib.from_global_key("a:k1") == 1     # untouched
    @test NGCSimLib.from_global_key("a:k2") == 99    # overwritten
    @test NGCSimLib.from_global_key("a:k3") == 3     # newly added
end

@testset "get_state returns defensive copy" begin
    NGCSimLib.reset_global_state!()
    NGCSimLib.add_key!("x", "v", 42)
    snap = NGCSimLib.get_state()
    @test snap["x:v"] == 42
    snap["x:v"] = 0          # mutate snapshot
    @test NGCSimLib.from_global_key("x:v") == 42   # singleton unchanged
end

@testset "compartment registry — add / get / missing-throws" begin
    # Need a concrete subtype of AbstractCompartmentLike. Per the protocol
    # contract in GlobalState.jl, subtypes must expose a `root_target::String`
    # field (the canonical global-state key).
    struct _ProbeCompartment <: NGCSimLib.AbstractCompartmentLike
        root_target::String
        value::Vector{Float64}
    end
    NGCSimLib.reset_global_state!()
    c = _ProbeCompartment("net.layer.W", [0.1, 0.2])
    NGCSimLib.add_compartment!(c)
    got = NGCSimLib.get_compartment("net.layer.W")
    @test got === c
    @test_throws KeyError NGCSimLib.get_compartment("does.not.exist")
end

@testset "thread-safety smoke — concurrent add_key! under @lock" begin
    NGCSimLib.reset_global_state!()
    n = 1000
    Threads.@threads for i in 1:n
        NGCSimLib.add_key!("t", string(i), i)
    end
    state = NGCSimLib.get_state()
    @test length(state) == n
    @test all(state["t:$i"] == i for i in 1:n)
end
