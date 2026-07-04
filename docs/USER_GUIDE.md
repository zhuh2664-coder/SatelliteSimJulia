# SatelliteSimJulia — 用户手册 / User Guide

> **状态 / Status**: 框架已就位，各场景内容待补全。
> This file was created to fix broken README links ([#3](https://github.com/zhuh2664-coder/SatelliteSimJulia/issues/3)). Detailed content TBD.

---

## 安装 / Installation

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

---

## 六个使用场景 / Six Usage Scenarios

### 场景 1 — 覆盖评估 / Coverage Assessment

```julia
using SatelliteSimJulia
result = assess_coverage(ConstellationIntent(coverage=GlobalCoverage(), scale=MediumScale()))
println("覆盖率: $(round(result.coverage_ratio*100, digits=1))%")
```

> TODO: 补充参数说明、输出字段解释、典型结果图。

---

### 场景 2 — 参数扫描 / Parameter Sweep

```julia
using SatelliteSimJulia
# sweep 轨道高度 vs 覆盖率
results = sweep(ExperimentConfig(...), :altitude, 400:50:1200)
```

> TODO: 补充 sweep API 完整签名与返回格式。

---

### 场景 3 — 星座对比 / Constellation Comparison

> TODO: 展示如何对比 Iridium / Starlink / OneWeb 三种星座配置的时延与覆盖指标。

---

### 场景 4 — AI 仿真助手 / AI Simulation Agent

```julia
using SatelliteSimJulia
agent_repl(LLMProvider())   # 需要设置 DEEPSEEK_API_KEY
```

> TODO: 补充自然语言示例 prompt 与对应的工具调用流程。

---

### 场景 5 — 可微优化 / Differentiable Optimization

```julia
using SatelliteSimJulia
optimize_coverage(loss, x0)   # 端到端梯度 + Adam
```

> TODO: 补充 loss 定义、初始参数格式、收敛曲线说明。

---

### 场景 6 — TLE 仿真 / TLE-based Simulation

> TODO: 展示如何从 TLE 数据源读取真实轨道并接入仿真流水线。

---

## 另见 / See Also

- [API 参考](API_REFERENCE.md)
- [开发者指南](DEVELOPER_GUIDE.md)
- [平台状态报告](PLATFORM_STATUS_REPORT.md)
