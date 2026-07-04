#!/usr/bin/env julia
# 增量1验证：意图层统一 + tle_based 真接 SGP4
#
# 检查项：
#   A. resolve_propagator(TleBasedProp()) == :sgp4（SGP4 标记）
#   B. _parse_propagator("tle_based") 不再返回 TwoBodyPropagator，而是 :sgp4
#   C. _parse_topology 通过意图层，与 resolve_topology 结果一致（消除两套词表）
#   D. tle_based 端到端：run_simulation(propagator="tle_based") 真跑 SGP4，用 catalog TLE
#
# 用法：julia --project=src/lab scripts/test_intent_unification.jl

using SatelliteSimLab
using SatelliteSimLab: resolve_propagator, resolve_topology, ResolutionContext,
                       _parse_topology, _parse_propagator, _topology_intent, _propagator_intent,
                       execute_tool, TwoBodyPropagator, J2Propagator, J4Propagator,
                       GridPlusStrategy, RingStrategy, BalancedTopo, HighRobustTopo,
                       LowCostTopo, TleBasedProp, SpeedFocus, BalancedProp, PrecisionFocus

const _KEY = get(ENV, "DEEPSEEK_API_KEY", "dummy-key-for-selftest")
ok = 0; fail = 0
function check(name, cond)
    global ok, fail
    if cond
        ok += 1; println("  ✓ $name")
    else
        fail += 1; println("  ✗ FAIL: $name")
    end
end

println("=== A. resolve_propagator SGP4 标记 ===")
check("TleBasedProp → :sgp4",        resolve_propagator(TleBasedProp(), ResolutionContext()) === :sgp4)
check("SpeedFocus → TwoBody",        resolve_propagator(SpeedFocus(), ResolutionContext()) isa TwoBodyPropagator)
check("BalancedProp → J2",           resolve_propagator(BalancedProp(), ResolutionContext()) isa J2Propagator)
check("PrecisionFocus → J4",         resolve_propagator(PrecisionFocus(), ResolutionContext()) isa J4Propagator)
check(":tle_based 符号 → :sgp4",     resolve_propagator(:tle_based, ResolutionContext()) === :sgp4)

println("\n=== B. _parse_propagator 不再假退回 TwoBody ===")
check("\"tle_based\" → :sgp4 (非 TwoBody)", _parse_propagator("tle_based") === :sgp4)
check("\"fast\" → TwoBody",            _parse_propagator("fast") isa TwoBodyPropagator)
check("\"balanced\" → J2",             _parse_propagator("balanced") isa J2Propagator)
check("\"precise\" → J4",              _parse_propagator("precise") isa J4Propagator)

println("\n=== C. _parse_topology 与意图层一致（单一真相源）===")
for (sym, intent) in (("balanced", BalancedTopo()), ("robust", HighRobustTopo()),
                       ("minimal", LowCostTopo()))
    via_agent = _parse_topology(sym, 66)
    via_intent = resolve_topology(intent, ResolutionContext(T=66))
    check("\"$sym\" 一致 ($via_agent == $via_intent)", typeof(via_agent) == typeof(via_intent))
end

println("\n=== D. tle_based 端到端：真跑 SGP4（catalog :starlink_tle）===")
result = execute_tool("run_simulation", Dict(
    "constellation" => "starlink_tle",
    "propagator" => "tle_based",
    "topology" => "balanced",
    "duration_s" => 60,
    "steps" => 3,
))
# execute_tool 经 post 钩子后返回字符串（LLM 消费），解析回 Dict 做断言
using JSON: parse as jsonparse
result = jsonparse(result)
if haskey(result, "error")
    check("SGP4 端到端无错", false)
    println("    错误: ", result["error"])
else
    check("返回 propagator=tle_based",     result["propagator"] == "tle_based")
    check("n_satellites > 0（真实 TLE 解析出卫星）", result["n_satellites"] > 0)
    check("tle_source > 0（用了 catalog TLE）",      result["tle_source"] > 0)
    check("avg_latency_ms 有限",           isfinite(result["avg_latency_ms"]))
    println("    n_satellites=$(result["n_satellites"]), tle_source=$(result["tle_source"]), ",
            "avg_latency=$(result["avg_latency_ms"])ms, connectivity=$(result["connectivity_ratio"])")
end

println("\n" * "=" ^ 50)
println("INTENT UNIFICATION + SGP4: $ok passed, $fail failed")
println("=" ^ 50)
exit(fail == 0 ? 0 : 1)
