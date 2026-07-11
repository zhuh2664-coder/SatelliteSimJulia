# SatelliteSimPlatformKubernetes

`SatelliteSimPlatformKubernetes` 是**边缘平台层**的 Kubernetes Job 渲染与客户端适配契约。它不依赖
`SatelliteSimCore` 或根伞包，也不会被仿真主链反向导入。

## 已实现

- `KubernetesJobSpec`：仅允许显式 image、namespace、service account、config object key、artifact prefix、
  CPU/memory 和有限的 TTL/backoff；
- `render_job`：确定性输出受限的 `batch/v1 Job` 字典；
- `AbstractKubernetesJobClient`：供真实集群适配器实现的提交、状态和取消边界；
- `FakeKubernetesJobClient`：离线测试的内存客户端。

渲染器不接受用户 PodSpec、hostPath、volume、`hostNetwork`、privileged container、任意 command/args 或任意
环境变量。容器固定为非 root、只读根文件系统、`allowPrivilegeEscalation=false`、`seccomp=RuntimeDefault`，并且
service account token 不自动挂载。image 必须有显式 tag 或 sha256 digest，明确拒绝 `:latest` 和 `default`
service account。

## 使用方式

```julia
using SatelliteSimPlatformKubernetes

spec = KubernetesJobSpec(
    job_id="alpha-run-001",
    image="ghcr.io/example/satellitesim-runner:2026-07-09",
    config_key="tenants/alpha/configs/run-001.json",
    output_prefix="tenants/alpha/jobs/run-001",
    resources=KubernetesResources(1000, 2048),
)
manifest = render_job(spec).manifest
```

真实 client 的凭据、TLS、集群 endpoint 和身份轮换必须由部署层注入；这个包不读取或持久化任何凭据。
本地只验证 manifest 和 fake client 生命周期：

```bash
julia --project=platform/kubernetes -e 'using Pkg; Pkg.test(; coverage=false)'
```

## 明确未实施

没有 Kubernetes SDK/HTTP client、没有 cluster discovery、没有运行时 admission webhook，也没有远程集群实测。
生产适配器上线前仍需实施最小 RBAC、namespace isolation、NetworkPolicy、image provenance、Pod Security
admission、审计日志以及真实集群的端到端验收。
