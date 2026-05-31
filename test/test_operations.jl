# test_operations.jl — coverage for src/core/Operations.jl

@testset "Summation: empty, single, multi" begin
    NGCSimLib.reset_global_state!()
    @test NGCSimLib.get_value(NGCSimLib.Summation()) == 0    # identity

    a = NGCSimLib.Compartment(3.0);
    NGCSimLib.setup!(a, "a", "n")
    b = NGCSimLib.Compartment(4.0);
    NGCSimLib.setup!(b, "b", "n")
    c = NGCSimLib.Compartment(5.0);
    NGCSimLib.setup!(c, "c", "n")

    @test NGCSimLib.get_value(NGCSimLib.Summation(a)) == 3.0
    @test NGCSimLib.get_value(NGCSimLib.Summation(a, b)) == 7.0
    @test NGCSimLib.get_value(NGCSimLib.Summation(a, b, c)) == 12.0
end

@testset "Product: empty, single, multi" begin
    NGCSimLib.reset_global_state!()
    @test NGCSimLib.get_value(NGCSimLib.Product()) == 1     # identity

    a = NGCSimLib.Compartment(2.0);
    NGCSimLib.setup!(a, "a", "n")
    b = NGCSimLib.Compartment(3.0);
    NGCSimLib.setup!(b, "b", "n")
    c = NGCSimLib.Compartment(4.0);
    NGCSimLib.setup!(c, "c", "n")

    @test NGCSimLib.get_value(NGCSimLib.Product(a)) == 2.0
    @test NGCSimLib.get_value(NGCSimLib.Product(a, b)) == 6.0
    @test NGCSimLib.get_value(NGCSimLib.Product(a, b, c)) == 24.0
end

@testset "Nested ops compose as expression tree" begin
    NGCSimLib.reset_global_state!()
    a = NGCSimLib.Compartment(2.0);
    NGCSimLib.setup!(a, "a", "n")
    b = NGCSimLib.Compartment(3.0);
    NGCSimLib.setup!(b, "b", "n")
    c = NGCSimLib.Compartment(4.0);
    NGCSimLib.setup!(c, "c", "n")

    # (a + b) * c = (2+3) * 4 = 20
    op = NGCSimLib.Product(NGCSimLib.Summation(a, b), c)
    @test NGCSimLib.get_value(op) == 20.0
end

@testset "Op-as-target on a Compartment" begin
    NGCSimLib.reset_global_state!()
    a = NGCSimLib.Compartment(2.0);
    NGCSimLib.setup!(a, "a", "n")
    b = NGCSimLib.Compartment(3.0);
    NGCSimLib.setup!(b, "b", "n")
    dest = NGCSimLib.Compartment(0.0);
    NGCSimLib.setup!(dest, "d", "n")

    op = NGCSimLib.Summation(a, b)
    NGCSimLib.target!(dest, op)
    @test dest.target === op
    # get_value recurses through the op
    @test NGCSimLib.get_value(dest) == 5.0
end

@testset ">> wiring with an op on the LHS" begin
    NGCSimLib.reset_global_state!()
    a = NGCSimLib.Compartment(2.0);
    NGCSimLib.setup!(a, "a", "n")
    b = NGCSimLib.Compartment(3.0);
    NGCSimLib.setup!(b, "b", "n")
    dest = NGCSimLib.Compartment(0.0);
    NGCSimLib.setup!(dest, "d", "n")

    op = NGCSimLib.Summation(a, b)
    op >> dest
    @test dest.target === op
    @test NGCSimLib.get_value(dest) == 5.0
end

@testset "get_needed_keys unions across operands" begin
    NGCSimLib.reset_global_state!()
    a = NGCSimLib.Compartment(0.0);
    NGCSimLib.setup!(a, "a", "n")
    b = NGCSimLib.Compartment(0.0);
    NGCSimLib.setup!(b, "b", "n")
    c = NGCSimLib.Compartment(0.0);
    NGCSimLib.setup!(c, "c", "n")
    op = NGCSimLib.Product(NGCSimLib.Summation(a, b), c)
    keys = NGCSimLib.get_needed_keys(op)
    @test keys == Set(["n:a", "n:b", "n:c"])
end

@testset "ast_kernel + lower (symbolic Dict-backed evaluation)" begin
    NGCSimLib.reset_global_state!()
    a = NGCSimLib.Compartment(2.0);
    NGCSimLib.setup!(a, "a", "n")
    b = NGCSimLib.Compartment(3.0);
    NGCSimLib.setup!(b, "b", "n")
    op = NGCSimLib.Summation(a, b)
    @test NGCSimLib.ast_kernel(op) === +
    # `lower(op, ctx)` produces the value when ctx is a plain Dict-of-keys.
    # Simulates what the JIT-trace path will do.
    ctx = Dict("n:a" => 2.0, "n:b" => 3.0)
    @test NGCSimLib.lower(op, ctx) == 5.0
end

@testset "single-operand op is a passthrough at lower()" begin
    NGCSimLib.reset_global_state!()
    a = NGCSimLib.Compartment(7.0);
    NGCSimLib.setup!(a, "a", "n")
    op = NGCSimLib.Summation(a)
    ctx = Dict("n:a" => 7.0)
    @test NGCSimLib.lower(op, ctx) == 7.0
end

@testset "Op arithmetic via inherited AbstractValueNode injection" begin
    NGCSimLib.reset_global_state!()
    a = NGCSimLib.Compartment(2.0);
    NGCSimLib.setup!(a, "a", "n")
    b = NGCSimLib.Compartment(3.0);
    NGCSimLib.setup!(b, "b", "n")
    op = NGCSimLib.Summation(a, b)
    # Ops inherit binary-op dispatch from Compartment.jl's @eval block
    # because AbstractOp <: AbstractValueNode.
    @test (op + 10) == 15.0
    @test (10 + op) == 15.0
    @test (op * 2) == 10.0
end
