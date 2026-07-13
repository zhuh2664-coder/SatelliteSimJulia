using Test

include(joinpath(@__DIR__, "..", "scripts", "test_all.jl"))

julia_eval(code::String) =
    `$(Base.julia_cmd()) --startup-file=no --history-file=no -e $code`

@testset "unified runner timeout configuration" begin
    ordinary = target("timeout-test", julia_eval("exit()"))
    @test ordinary.timeout_seconds === nothing

    bounded = target("timeout-test", julia_eval("exit()"); timeout_seconds=2.5)
    @test bounded.timeout_seconds == 2.5
    @test_throws ArgumentError target(
        "timeout-test",
        julia_eval("exit()");
        timeout_seconds=0,
    )

    withenv("SATSIM_GPU_TIMEOUT_SECONDS" => nothing) do
        gpu = only(item for item in build_targets() if item.name == "gpu-a10g")
        @test gpu.timeout_seconds == 45 * 60
    end
    withenv("SATSIM_GPU_TIMEOUT_SECONDS" => "12.5") do
        gpu = only(item for item in build_targets() if item.name == "gpu-a10g")
        @test gpu.timeout_seconds == 12.5
    end
end

@testset "exact Modal PASS marker" begin
    sentinel = "MODAL_GPU_VALIDATION status=PASS suite=sgp4_cuda"
    @test marker_for("$sentinel\n") == sentinel
    @test marker_for("prefix $sentinel\n") == "exit 0"
    @test marker_for("$sentinel suffix\n") == "exit 0"
    @test marker_for("MODAL_GPU_VALIDATION status=FAIL suite=sgp4_cuda\n") == "exit 0"
end

@testset "subprocess outcomes" begin
    ok, duration, output = run_command(julia_eval("println(\"NORMAL_SUCCESS\")"))
    @test ok
    @test duration >= 0
    @test output == "NORMAL_SUCCESS\n"

    ok, _, output = run_command(
        julia_eval("println(stderr, \"NONZERO_EXIT\"); exit(7)"),
    )
    @test !ok
    @test occursin("NONZERO_EXIT", output)
    @test isempty(timeout_marker_for(output))

    sleeping = julia_eval(
        "println(\"SLEEP_STARTED\"); flush(stdout); sleep(30); println(\"SLEEP_FINISHED\")",
    )
    ok, duration, output = run_command(sleeping; timeout_seconds=1.0)
    @test !ok
    @test duration < 5
    @test occursin("SLEEP_STARTED", output)
    @test !occursin("SLEEP_FINISHED", output)
    @test timeout_marker_for(output) == "PROCESS_TIMEOUT timeout_seconds=1.0"
end
