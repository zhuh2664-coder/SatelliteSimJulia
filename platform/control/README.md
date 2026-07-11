# SatelliteSimPlatformControl

`SatelliteSimPlatformControl` 是平台的**边缘提交控制面**：它把已验证身份、租户配额、受限 JSON 配置、
Storage object namespace 和 Kubernetes Job 渲染组合起来。它只依赖 `platform/` 包和既有 `PlatformRunner`
配置验证，不向 Foundation → Orbit → Link → Net → Metrics/Traffic → Core → Lab 主链注入鉴权、云 SDK、数据库或
Kubernetes 依赖。

## 已实现的本地契约

1. `AbstractIdentityVerifier`：生产 OIDC/mTLS/SSO 实现应在此边界外验证 claims；
   `StaticIdentityVerifier` 仅用于本地测试，不是生产认证机制，也不持久化 API key；
2. `AuthenticatedPrincipal`：tenant、subject 和 role 显式传递；只有 `:submit` / `:admin` 可提交；
3. `AbstractQuotaStore` 和 `InMemoryQuotaStore`：按 tenant 预留并隔离并发 jobs、CPU、memory、每日 job 数和
   声明的 artifact bytes；相同 `(tenant, idempotency_key)` 仅能幂等重放同一请求；
4. `PlatformControlPlane`：先验证 schema，再预留 quota，写入 `tenants/<tenant>/...` object key，最后提交受限
   Kubernetes Job；失败会释放已创建的 quota reservation；
5. `sync_submission!` / `cancel_submission!`：在 Fake Kubernetes client 返回 terminal state 后释放 reservation。

```julia
using SatelliteSimPlatformControl
using SatelliteSimPlatformKubernetes
using SatelliteSimPlatformStorage

# 仅本地开发/测试：真实部署必须替换为经过验证的 identity adapter 和持久化 quota store。
verifier = StaticIdentityVerifier(Dict(
    "local-alice" => AuthenticatedPrincipal("alpha", "alice", [:submit]),
))
quotas = InMemoryQuotaStore()
set_quota_policy!(quotas, "alpha", QuotaPolicy(
    max_concurrent_jobs=2, max_cpu_millicores=4000, max_memory_mib=8192,
    max_daily_jobs=20, max_artifact_bytes=10_000_000,
))
plane = PlatformControlPlane(
    verifier, quotas, LocalFilesystemStorage("/tmp/satellitesim-objects"), FakeKubernetesJobClient();
    image="ghcr.io/example/satellitesim-runner:2026-07-09",
)
```

## 验证

```bash
julia --project=platform/control -e 'using Pkg; Pkg.test(; coverage=false)'
```

测试证明：未认证/无 submit role 被拒绝、同租户配额不能超用、不同 tenant 不互相消耗 quota、同一 idempotency key
不会重复创建 Job、terminal/cancel 状态会释放 reservation、公开配置不能注入 PodSpec。

## 明确未实施

没有 HTTP/gRPC API、真实 OIDC/JWKS 验签、数据库/分布式 lease、S3/MinIO、真实 Kubernetes client、计量结算、
审计不可变存储、组织/项目层级或公网服务。`InMemoryQuotaStore` 不能跨进程/跨副本做原子预留，因此不得作为
生产多租户 quota store。
