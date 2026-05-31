# test_help.jl — coverage for src/support/Help.jl

@testset "GuideKind enum + guide_string" begin
    @test NGCSimLib.guide_string(NGCSimLib.GuideInput) == "input"
    @test NGCSimLib.guide_string(NGCSimLib.GuideOutput) == "output"
    @test NGCSimLib.guide_string(NGCSimLib.GuideParameters) == "params"
    @test NGCSimLib.guide_string(NGCSimLib.GuideMonitoring) == "monitoring"
    @test NGCSimLib.guide_string(NGCSimLib.GuideWiring) == "wiring"
end

const _PROBE_HELP = Dict(
    "compartments" => Dict(
        "inputs" => Dict("x" => "input signal"),
        "outputs" => Dict("y" => "predicted output")
    ),
    "hyperparameters" => Dict("lr" => "learning rate")
)

@testset "render_guide produces title + section content" begin
    s = NGCSimLib.render_guide(_PROBE_HELP, NGCSimLib.GuideInput)
    @test occursin("Input Guide", s)
    @test occursin("Input Compartments", s)
    @test occursin("x", s)
    @test occursin("input signal", s)
end

@testset "render_guide on empty data shows blank message" begin
    s = NGCSimLib.render_guide(Dict{String, Any}(), NGCSimLib.GuideInput)
    @test occursin("There are no required inputs", s)
end

@testset "guides() returns NamedTuple with five string fields" begin
    g = NGCSimLib.guides(_PROBE_HELP)
    @test g isa NamedTuple
    @test propertynames(g) == (:inputs, :outputs, :params, :monitoring, :wiring)
    @test occursin("Input Guide", g.inputs)
    @test occursin("Output Guide", g.outputs)
    @test occursin("Parameter Guide", g.params)
    @test occursin("Monitoring Guide", g.monitoring)
    @test occursin("Wiring Guide", g.wiring)
    # Wiring includes BOTH input and output sections (spec line 760)
    @test occursin("Input Compartments", g.wiring)
    @test occursin("Output Compartments", g.wiring)
end

@testset "render_guide(GuideMonitoring) renders output section (bug intentionally NOT ported)" begin
    s = NGCSimLib.render_guide(_PROBE_HELP, NGCSimLib.GuideMonitoring)
    @test occursin("Monitoring Guide", s)
    @test occursin("Output Compartments", s)
end
