# test_modules.jl — coverage for src/support/Modules.jl

@testset "check_attributes" begin
    obj = (name="thing", x=1, y=2)        # NamedTuple
    @test NGCSimLib.check_attributes(obj, nothing) == true
    @test NGCSimLib.check_attributes(obj, [:x, :y]) == true
    @test NGCSimLib.check_attributes(obj, [:x, :z]) == false
    @test_throws ErrorException NGCSimLib.check_attributes(obj, [:nope]; fatal=true)
end

@testset "load_module discovers a loaded module by last component" begin
    NGCSimLib.reset_module_caches!()
    m = NGCSimLib.load_module("NGCSimLib")
    @test m === NGCSimLib
    # cache hit on second call
    m2 = NGCSimLib.load_module("NGCSimLib")
    @test m2 === m
end

@testset "load_module raises on no-match" begin
    NGCSimLib.reset_module_caches!()
    @test_throws ErrorException NGCSimLib.load_module("ThisModuleDoesNotExistAnywhere")
end

@testset "load_attribute capitalises first letter by default" begin
    NGCSimLib.reset_module_caches!()
    # NGCSimLib exports `NGCSIMLIB_VERSION` — we'll look up something we know exists.
    # The first-char-capitalise rule means "ngcSimLib" lookup would become "NgcSimLib",
    # which doesn't exist. So pick an attribute whose first char is already upper.
    v = NGCSimLib.load_attribute("NGCSIMLIB_VERSION"; module_path="NGCSimLib", match_case=true)
    @test v == NGCSimLib.NGCSIMLIB_VERSION
end

@testset "load_attribute match_case=false uppercases first char only" begin
    NGCSimLib.reset_module_caches!()
    # Define a temp module with a CamelCase export
    Core.eval(Main, :(module _LoadAttrProbeMod
        struct RateCell; v::Int; end
        export RateCell
    end))
    # Calling load_attribute("rateCell") should look up "RateCell" via the
    # first-char-upper rule.
    T = NGCSimLib.load_attribute("rateCell"; module_path="_LoadAttrProbeMod")
    @test T === Main._LoadAttrProbeMod.RateCell
end

@testset "load_attribute raises on missing attribute" begin
    NGCSimLib.reset_module_caches!()
    @test_throws ErrorException NGCSimLib.load_attribute("DoesNotExist"; module_path="NGCSimLib", match_case=true)
end
