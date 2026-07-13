using Test

include(joinpath(@__DIR__, "..", "scripts", "test_all.jl"))

julia_eval(code::String) =
    `$(Base.julia_cmd()) --startup-file=no --history-file=no -e $code`

@testset "target selection and tier gates" begin
    @test isempty(parse_target_filter(""))
    @test parse_target_filter(" Runner-Timeout,AD-Validation ") ==
          Set(["runner-timeout", "ad-validation"])
    @test_throws ArgumentError parse_target_filter("runner-timeout,")
    @test_throws ArgumentError runner_config(
        env=Dict("SATSIM_RUN_OPTIONAL" => "true"),
    )

    selected_targets = build_targets(
        RunnerConfig(only=Set(["runner-timeout"])),
    )
    runner_timeout = only(
        item for item in selected_targets if item.name == "runner-timeout"
    )
    platform = only(item for item in selected_targets if item.name == "platform")
    @test runner_timeout.enabled
    @test !platform.enabled
    @test platform.reason == "filtered by SATSIM_TEST_ONLY"
    @test_throws ArgumentError build_targets(
        RunnerConfig(only=Set(["not-a-target"])),
    )

    default_targets = build_targets(RunnerConfig())
    optional_ad = only(
        item for item in default_targets if item.name == "ad-validation"
    )
    nightly_accuracy = only(
        item for item in default_targets if item.name == "orbit-accuracy"
    )
    nightly_validation = only(
        item for item in default_targets if item.name == "orbit-validation"
    )
    @test !optional_ad.enabled
    @test occursin("SATSIM_RUN_OPTIONAL=1", optional_ad.reason)
    @test !nightly_accuracy.enabled
    @test !nightly_validation.enabled
    @test occursin("SATSIM_RUN_NIGHTLY=1", nightly_accuracy.reason)

    optional_targets = build_targets(RunnerConfig(run_optional=true))
    optional_ad_without_data = only(
        item for item in optional_targets if item.name == "ad-validation"
    )
    @test !optional_ad_without_data.enabled
    @test occursin("SATSIM_TLE_PATH", optional_ad_without_data.reason)
    optional_with_data = build_targets(
        RunnerConfig(run_optional=true, ad_tle_path=@__FILE__),
    )
    @test only(
        item for item in optional_with_data if item.name == "ad-validation"
    ).enabled
    nightly_targets = build_targets(RunnerConfig(run_nightly=true))
    @test only(
        item for item in nightly_targets if item.name == "orbit-accuracy"
    ).enabled
    @test only(
        item for item in nightly_targets if item.name == "orbit-validation"
    ).enabled

    output = IOBuffer()
    print_target_list(output, selected_targets)
    listing = String(take!(output))
    @test occursin("runner-timeout", listing)
    @test occursin("RUN", listing)
    @test occursin("platform", listing)
    @test occursin("filtered by SATSIM_TEST_ONLY", listing)

    wrapped = addenv(
        julia_eval("exit()"),
        "SATSIM_TEST_SECRET" => "must-not-appear",
    )
    redacted_output = IOBuffer()
    print_target_list(
        redacted_output,
        [target("redaction-test", wrapped)],
    )
    redacted_listing = String(take!(redacted_output))
    @test occursin("[environment redacted]", redacted_listing)
    @test !occursin("must-not-appear", redacted_listing)
end

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

    targets = build_targets(RunnerConfig())
    platform = only(item for item in targets if item.name == "platform")
    selftest = only(item for item in targets if item.name == "runner-timeout")
    ad = only(item for item in targets if item.name == "ad-validation")
    orbit = only(item for item in targets if item.name == "orbit-accuracy")
    @test platform.timeout_seconds == 10 * 60
    @test selftest.timeout_seconds == 30
    @test ad.timeout_seconds == 15 * 60
    @test orbit.timeout_seconds == 10 * 60
end

@testset "exact success markers" begin
    sentinel = "MODAL_GPU_VALIDATION status=PASS suite=sgp4_cuda"
    @test marker_for("$sentinel\n") == sentinel
    @test marker_for("prefix $sentinel\n") == "exit 0"
    @test marker_for("$sentinel suffix\n") == "exit 0"
    @test marker_for("MODAL_GPU_VALIDATION status=FAIL suite=sgp4_cuda\n") == "exit 0"

    ad = "STEP1_OK"
    @test marker_matching("$ad\n", AD_VALIDATION_MARKER) == ad
    @test validated_outcome(true, "$ad\n", AD_VALIDATION_MARKER) == (true, ad)
    @test validated_outcome(false, "$ad\n", AD_VALIDATION_MARKER) == (false, "")

    orbit = "ORBIT_ACCURACY_VALIDATION status=PASS mode=walker-smoke rows=6"
    @test marker_matching("$orbit\n", ORBIT_ACCURACY_MARKER) == orbit
    @test isempty(marker_matching(
        "ORBIT_ACCURACY_VALIDATION status=PASS mode=walker-smoke rows=0\n",
        ORBIT_ACCURACY_MARKER,
    ))
    marker_ok, missing = validated_outcome(true, "ordinary output\n", ORBIT_ACCURACY_MARKER)
    @test !marker_ok
    @test startswith(missing, MISSING_SUCCESS_MARKER)

    validation = "ORBIT_VALIDATION status=PASS backend=ka_cpu"
    @test marker_matching("$validation\n", ORBIT_VALIDATION_MARKER) == validation
    selftest = "UNIFIED_RUNNER_SELFTEST status=PASS"
    @test marker_matching("$selftest\n", RUNNER_SELFTEST_MARKER) == selftest
    @test marker_for("\e[0m\e[1mTest Summary:\e[22m\e[39m\n") ==
          "Test Summary:"
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

println("UNIFIED_RUNNER_SELFTEST status=PASS")
