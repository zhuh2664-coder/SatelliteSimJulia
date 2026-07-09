# SatelliteSimJulia 遗留测试套件（归档 API，不保证通过）
#
# ⚠️ 本文件不应用于 `Pkg.test()` 默认入口。
#    活跃、低成本 API 测试见 `test/runtests.jl`。
#
# 运行方式（任选其一）：
#   SATSIM_RUN_LEGACY=1 julia --project=. test/runtests_legacy.jl
#   SATSIM_RUN_LEGACY=1 julia --project=. test/runtests_legacy_runnable.jl  # 活跃 API 对齐子集
#   SATSIM_RUN_LEGACY=1 julia --project=. test/runtests.jl
#
# 归档 API 段（StarPerf/testbed/旧 Satellite 模型）默认跳过；
# 尝试运行：SATSIM_RUN_LEGACY=1 SATSIM_RUN_LEGACY_ARCHIVE=1 julia --project=. test/runtests_legacy.jl
#
# 直接运行本文件且未设置 SATSIM_RUN_LEGACY=1 时，仅输出跳过说明。

push!(LOAD_PATH, "@stdlib")
using Test

if get(ENV, "SATSIM_RUN_LEGACY", "0") != "1"
    println(stderr, """
    [runtests_legacy] 已跳过：归档 API 测试不保证通过。
    请使用 test/runtests.jl（默认活跃 API 测试）。
    若需运行本套件：SATSIM_RUN_LEGACY=1 julia --project=. test/runtests_legacy.jl
    """)
    @testset "legacy archive (skipped)" begin
        @test_skip "需 SATSIM_RUN_LEGACY=1，见文件头说明"
    end
else
    include(joinpath(@__DIR__, "_runtests_legacy_body.jl"))
end
