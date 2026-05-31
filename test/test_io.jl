# test_io.jl — coverage for src/support/IO.jl

@testset "make_safe_filename" begin
    @test NGCSimLib.make_safe_filename("hello world") == "hello_world"
    @test NGCSimLib.make_safe_filename("a/b\\c|d?e*f") == "a_b_c_d_e_f"
    # Upstream: regex replaces spaces with `_` FIRST, then `.strip()` is a no-op
    # because the spaces have already become `_`. So trailing spaces become `___`
    # — port matches this 1:1.
    @test NGCSimLib.make_safe_filename("trail   ") == "trail___"
    @test NGCSimLib.make_safe_filename("hi\x00bye") == "hi_bye"
    # custom replacement char
    @test NGCSimLib.make_safe_filename("a b"; replacement="-") == "a-b"
end

@testset "make_unique_path with explicit name" begin
    base = mktempdir()
    p1 = NGCSimLib.make_unique_path(base, "model_run")
    @test isdir(p1)
    @test endswith(p1, "model_run")
    # second call with same name → appended uuid
    p2 = NGCSimLib.make_unique_path(base, "model_run")
    @test isdir(p2)
    @test p2 != p1
    @test occursin("model_run_", p2)
    rm(base; recursive=true, force=true)
end

@testset "make_unique_path without name → uuid" begin
    base = mktempdir()
    p = NGCSimLib.make_unique_path(base, nothing)
    @test isdir(p)
    rm(base; recursive=true, force=true)
end

@testset "check_serializable" begin
    @test isempty(
        NGCSimLib.check_serializable(Dict("a" => 1, "b" => "two", "c" => [1, 2, 3]))
    )
    # JSON3 rejects Task instances (no fallback reflection path). Mirrors
    # Python's json.dumps refusing thread/file handles. Most plain structs
    # JSON3 will reflect-into successfully — we need a value the lib actually
    # refuses, which is the relevant signal for `check_serializable`.
    t = @task 1 + 1
    bad = NGCSimLib.check_serializable(Dict("ok" => 1, "bad" => t))
    @test "bad" in bad
end
