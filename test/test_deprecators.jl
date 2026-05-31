# test_deprecators.jl — coverage for src/support/Deprecators.jl

@testset "@deprecated wraps and registers" begin
    orig = (x, y) -> x + y
    wrapped = NGCSimLib.@deprecated orig
    @test NGCSimLib.is_deprecated(wrapped)
    @test NGCSimLib.original_of(wrapped) === orig
    # Wrapper still forwards
    @test wrapped(2, 3) == 5
end

@testset "is_deprecated false on plain function" begin
    plain = (x) -> 2x
    @test !NGCSimLib.is_deprecated(plain)
    @test NGCSimLib.original_of(plain) === plain   # returns self when not wrapped
end

@testset "deprecate_args renames kwargs and drops with nothing" begin
    # Original: receives `new_name`, returns it
    orig = (; new_name=:default, kept=:k) -> (new_name, kept)
    wrapped = NGCSimLib.deprecate_args(orig;
        renames=Dict(:old_name => :new_name, :gone => nothing))
    @test NGCSimLib.is_deprecated(wrapped)

    # Rename path — old_name forwarded as new_name
    @test wrapped(; old_name=:hello, kept=:k) == (:hello, :k)
    # Removal path — `gone` gets dropped silently (warn emitted)
    @test wrapped(; gone=:x, kept=:k) == (:default, :k)
    # Untouched kwargs pass through
    @test wrapped(; new_name=:direct, kept=:k) == (:direct, :k)
end

@testset "deprecate_args with rebind=false only warns" begin
    orig = (; old_name=nothing) -> old_name
    wrapped = NGCSimLib.deprecate_args(orig;
        rebind=false,
        renames=Dict(:old_name => :new_name))
    # rebind=false → old kwarg is NOT dropped; original still receives it
    @test wrapped(; old_name=:still_here) == :still_here
end

@testset "deprecate_args rejects bad rename values" begin
    orig = (; x=1) -> x
    @test_throws ErrorException NGCSimLib.deprecate_args(orig;
        renames=Dict(:old => 42))   # 42 is neither nothing nor symbol/string
end
