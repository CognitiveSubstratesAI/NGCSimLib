# test_logger.jl — coverage for src/support/Logger.jl

using Logging

@testset "Public surface exports" begin
    @test isdefined(NGCSimLib, :ngc_warn)
    @test isdefined(NGCSimLib, :ngc_info)
    @test isdefined(NGCSimLib, :ngc_debug)
    @test isdefined(NGCSimLib, :ngc_error)
    @test isdefined(NGCSimLib, :ngc_critical)
    @test isdefined(NGCSimLib, :add_logging_level)
    @test isdefined(NGCSimLib, :custom_log)
    @test isdefined(NGCSimLib, :init_logging)
end

@testset "ngc_warn / ngc_info / ngc_debug do NOT raise" begin
    # These should return nothing without throwing, matching upstream `warn()`
    # `info()` `debug()` (logger.py:108-118, 150-160, 163-173).
    @test NGCSimLib.ngc_warn("hello") === nothing
    @test NGCSimLib.ngc_info("hello") === nothing
    @test NGCSimLib.ngc_debug("hello") === nothing
end

@testset "ngc_error raises (control flow per spec)" begin
    # Upstream `error()` raises errorCls(msg). Default Julia errortype is
    # ErrorException; caller can override via errortype kwarg.
    @test_throws ErrorException NGCSimLib.ngc_error("boom")
    @test_throws ArgumentError NGCSimLib.ngc_error("bad arg"; errortype=ArgumentError)
end

@testset "ngc_critical raises ErrorException (errortype NOT configurable)" begin
    # Upstream `critical()` always raises RuntimeError regardless of caller.
    # We map to ErrorException; the errortype knob is intentionally not exposed.
    @test_throws ErrorException NGCSimLib.ngc_critical("kaboom")
end

@testset "Varargs concatenation (print-style)" begin
    # Mirrors Python _concatArgs: `warn("a", b, "c")` → "a {b} c"
    try
        NGCSimLib.ngc_error("kwarg", "logging_file", "is deprecated")
    catch e
        @test e isa ErrorException
        @test occursin("kwarg logging_file is deprecated", sprint(showerror, e))
    end
end

@testset "Custom log levels — registration + dispatch" begin
    # Register a custom level, then dispatch via custom_log
    NGCSimLib.add_logging_level(:TRACE, 5)
    # Re-registering with same name raises (upstream lines 47, 50, 53)
    @test_throws ErrorException NGCSimLib.add_logging_level(:TRACE, 5)
    # custom_log on a registered level returns nothing (emits)
    @test NGCSimLib.custom_log("trace message", :TRACE) === nothing
    @test NGCSimLib.custom_log("trace message", 5) === nothing
    # Unregistered level → warn-and-skip, returns nothing without raising
    @test NGCSimLib.custom_log("ignored", :NONEXISTENT) === nothing
    # No level supplied → warn-and-skip
    @test NGCSimLib.custom_log("ignored") === nothing
end

@testset "init_logging — idempotent, string-level resolution" begin
    # Default config (no kwargs) installs a stderr ConsoleLogger at Error.
    @test NGCSimLib.init_logging() === nothing
    # String level resolved case-insensitively.
    @test NGCSimLib.init_logging(logging_level="info") === nothing
    @test NGCSimLib.init_logging(logging_level=:DEBUG) === nothing
    # Numeric level passes through to LogLevel.
    @test NGCSimLib.init_logging(logging_level=1500) === nothing
    # hide_console=true with no file → NullLogger (no output sink at all).
    @test NGCSimLib.init_logging(; hide_console=true) === nothing
    # Reset back to default for downstream tests.
    NGCSimLib.init_logging()
end

@testset "init_logging — file output writes UTC banner" begin
    tmpfile = tempname() * ".log"
    NGCSimLib.init_logging(; logging_file=tmpfile, logging_level=Logging.Info)
    NGCSimLib.ngc_info("hello from logger test")
    # Reset so later tests don't write to this temp file
    NGCSimLib.init_logging()
    sleep(0.05)
    content = read(tmpfile, String)
    @test occursin("~~~~~/New Log", content)
    rm(tmpfile; force=true)
end

@testset "Unknown level resolution raises" begin
    @test_throws ErrorException NGCSimLib.init_logging(logging_level=:NOPE)
end
