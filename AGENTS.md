# AGENTS.md — SatelliteSimJulia 协作约束

本文件约束人类与 AI 在本仓库中的改动方式。若旧计划、归档文档或注释与这里冲突，以 `README.md`、`CURRENT.md`、本文件和实测结果为准。

## 1. 当前主线

主线是可复现的 LEO 网络仿真流水线：

```text
Foundation → Orbit → Link → Net → Metrics / Traffic → Core → Lab
```

数据契约优先使用普通 Julia 数组；轨道位置统一为 `(satellite, time, xyz)`，ECEF，km。`SubArray` 等 `AbstractArray` 视图必须能通过主链，不能为了类型签名强制复制。

## 2. 包边界

- 下层包不得依赖上层聚合包。
- `Net`、`Traffic`、`Security`、`Opt` 不得依赖 `SatelliteSimCore`。
- 每个本地依赖都必须在自己的 `Project.toml` 中有显式 `[sources]`。
- `Opt`、`Security`、`Viz`、`GMAT` 是显式选择的可选环境，不从根伞包隐式 re-export；Core/Net/Traffic/Lab 的兼容 re-export 本轮保留。
- 外部轨道实现通过 `SatelliteSimBackends` 契约接入；主链不能直接依赖重型后端。

修改依赖后先运行：

```bash
julia scripts/check_dependency_boundaries.jl
julia scripts/check_manifest_baseline.jl
```

## 3. 验证顺序

优先小步验证，再扩大范围：

```bash
julia --project=envs/core test/runtests_core_smoke.jl
julia --project=envs/core test/test_bare_array_contract.jl
julia --project=src/link -e 'using Pkg; Pkg.test(; coverage=false)'
julia --project=src/net -e 'using Pkg; Pkg.test(; coverage=false)'
julia --project=src/traffic -e 'using Pkg; Pkg.test(; coverage=false)'
julia --project=src/lab -e 'using Pkg; Pkg.test(; coverage=false)'
```

统一入口：

```bash
julia --project=. scripts/test_all.jl
SATSIM_RUN_OPTIONAL=1 julia --project=. scripts/test_all.jl
```

在受限沙箱中，`Pkg.test` 可能因为无法写 `~/.julia` 或无法绑定 localhost 出现环境性失败；应在获准环境重跑，不能据此修改业务逻辑来“适配”假失败。

## 4. 文档规则

- `CURRENT.md`：唯一现状入口。
- `重构计划.md`：从属于 `CURRENT.md` 的短期执行清单；本轮完成后迁入 `docs/archive/`。
- `docs/design/dependency-isolation.md`：依赖与后端隔离设计正本。
- 不新建另一份“总路线图”。旧材料只作为证据或背景，不作为完成状态。

## 5. 安全与工作区

- 不执行 `git reset --hard`、`git clean`，不删除 stash，不覆盖用户未提交修改。
- 不主动 push/fetch；远程操作必须由用户明确要求。
- 不读取、打印、复制或写入 PAT、API key、带凭据的 remote URL。
- 不提交 `.cursor/`、运行日志、生成数据或包内临时 Manifest。
- 论文、文献、Godot/Unity、平台实验和大体积归档默认冻结；除非任务明确要求，不重写、不搬迁。
