# test_compartment.jl — coverage for src/core/Compartment.jl

@testset "Compartment construction defaults" begin
    c = NGCSimLib.Compartment([0.0, 0.0])
    @test c.initial_value == [0.0, 0.0]
    @test c.name === nothing
    @test c.root_target === nothing
    @test c.target === nothing
    @test c.auto_save == true
    # accessors agree with fields
    @test NGCSimLib.root(c) === nothing
    @test NGCSimLib.targeted(c) == true   # target === nothing → not String, so targeted=true
    @test NGCSimLib.target(c) === nothing
end

@testset "setup! → root_target + auto-default target + global state write" begin
    NGCSimLib.reset_global_state!()
    c = NGCSimLib.Compartment([1.0, 2.0, 3.0])
    NGCSimLib.setup!(c, "voltage", "net.layer")
    @test c.name == "voltage"
    @test c.root_target == "net.layer:voltage"
    @test c.target == "net.layer:voltage"
    @test NGCSimLib.root(c) == "net.layer:voltage"
    @test NGCSimLib.targeted(c) == false
    # initial value pushed into global state
    @test NGCSimLib.from_global_key("net.layer:voltage") == [1.0, 2.0, 3.0]
    # registered with the manager
    @test NGCSimLib.get_compartment("net.layer:voltage") === c
end

@testset "set! self-slot write goes through; foreign-slot write aborts" begin
    NGCSimLib.reset_global_state!()
    a = NGCSimLib.Compartment([0.0])
    b = NGCSimLib.Compartment([0.0])
    NGCSimLib.setup!(a, "a", "net")
    NGCSimLib.setup!(b, "b", "net")
    NGCSimLib.set!(a, [99.0])
    @test NGCSimLib.from_global_key("net:a") == [99.0]
    # Foreign target — wire b to read from a
    NGCSimLib.target!(b, "net:a")
    @test b.target == "net:a"
    # set! on foreign slot should warn and abort (no write through)
    NGCSimLib.set!(b, [123.0])
    @test NGCSimLib.from_global_key("net:a") == [99.0]   # unchanged
end

@testset "set! pre-setup buffers in initial_value" begin
    c = NGCSimLib.Compartment([0.0])
    NGCSimLib.set!(c, [42.0])
    @test c.initial_value == [42.0]
end

@testset "get_value resolves chain: pre-setup, own slot, foreign slot, op" begin
    NGCSimLib.reset_global_state!()
    c = NGCSimLib.Compartment([7.0])
    @test NGCSimLib.get_value(c) == [7.0]    # pre-setup → initial_value
    NGCSimLib.setup!(c, "v", "net")
    @test NGCSimLib.get_value(c) == [7.0]    # own slot, read-through

    other = NGCSimLib.Compartment([99.0])
    NGCSimLib.setup!(other, "w", "net")
    NGCSimLib.target!(c, other)
    # one-hop chase: c.target becomes other.target ("net:w")
    @test c.target == "net:w"
    @test NGCSimLib.get_value(c) == [99.0]
end

@testset ">> wiring (source >> dest) retargets dest" begin
    NGCSimLib.reset_global_state!()
    a = NGCSimLib.Compartment([1.0])
    b = NGCSimLib.Compartment([0.0])
    NGCSimLib.setup!(a, "a", "n")
    NGCSimLib.setup!(b, "b", "n")
    a >> b
    @test b.target == "n:a"
    @test NGCSimLib.get_value(b) == [1.0]
end

@testset "arithmetic injection (unwrap + dispatch)" begin
    NGCSimLib.reset_global_state!()
    a = NGCSimLib.Compartment(3.0)
    b = NGCSimLib.Compartment(4.0)
    NGCSimLib.setup!(a, "a", "n")
    NGCSimLib.setup!(b, "b", "n")
    # Both orders work via multiple dispatch (no upstream __rsub__ bug)
    @test (a + b) == 7.0
    @test (a - b) == -1.0
    @test (b - a) == 1.0
    @test (5 - a) == 2.0          # reverse-op correctness
    @test (a * 2) == 6.0
    @test (a < b) == true
    @test (a == 3.0) == true
end

@testset "get_needed_keys returns full key, not chars (upstream bug NOT ported)" begin
    NGCSimLib.reset_global_state!()
    c = NGCSimLib.Compartment([0.0])
    NGCSimLib.setup!(c, "v", "net.layer")
    keys = NGCSimLib.get_needed_keys(c)
    @test keys == Set(["net.layer:v"])
    @test length(keys) == 1           # not split into chars
end

@testset "target! rejects foreign types" begin
    c = NGCSimLib.Compartment([0.0])
    @test_throws ErrorException NGCSimLib.target!(c, 42)
    @test_throws ErrorException NGCSimLib.target!(c, [1, 2, 3])
end

@testset "show prints meaningful repr" begin
    NGCSimLib.reset_global_state!()
    c = NGCSimLib.Compartment(7.0)
    s_pre = sprint(show, c)
    @test occursin("<un-setup>", s_pre)
    NGCSimLib.setup!(c, "v", "net")
    s_post = sprint(show, c)
    @test occursin("net:v", s_post)
    @test occursin("7.0", s_post)
end
