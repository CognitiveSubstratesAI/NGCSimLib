# test_config.jl — coverage for src/support/Config.jl

@testset "get_config returns nothing before init_config" begin
    NGCSimLib.reset_config!()
    @test NGCSimLib.get_config("anything") === nothing
    @test NGCSimLib.provide_namespace("anything") === nothing
end

@testset "init_config + get_config round-trip" begin
    NGCSimLib.reset_config!()
    tmp = tempname() * ".json"
    write(tmp, """
        {"logging": {"logging_level": "info", "hide_console": false},
         "modules": {"path": "ngclearn.components"}}
    """)
    @test NGCSimLib.init_config(tmp) === nothing
    log_cfg = NGCSimLib.get_config("logging")
    @test log_cfg isa AbstractDict
    @test log_cfg["logging_level"] == "info"
    @test log_cfg["hide_console"]  == false
    @test NGCSimLib.get_config("missing_section") === nothing
    rm(tmp; force=true)
end

@testset "provide_namespace yields a NamedTuple" begin
    NGCSimLib.reset_config!()
    tmp = tempname() * ".json"
    write(tmp, """{"logging": {"logging_level": "warn", "hide_console": true}}""")
    NGCSimLib.init_config(tmp)
    ns = NGCSimLib.provide_namespace("logging")
    @test ns isa NamedTuple
    @test ns.logging_level == "warn"
    @test ns.hide_console  == true
    @test NGCSimLib.provide_namespace("absent") === nothing
    rm(tmp; force=true)
end

@testset "init_config on missing file raises" begin
    @test_throws SystemError NGCSimLib.init_config("/tmp/__definitely_does_not_exist_$(rand(UInt32)).json")
end
