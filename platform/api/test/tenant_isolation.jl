# tenant_isolation.jl — 越权访问集成测试
# 验证 alice 创建的 job 不能被 bob 访问

using Test
using HTTP
using JSON
using UUIDs
using Storage

const API = "http://localhost:8080"

function _post(path, body; token = "")
    headers = ["Content-Type" => "application/json"]
    isempty(token) || push!(headers, "Authorization" => "Bearer $token")
    return HTTP.post("$API$path", headers; body = JSON.json(body))
end

function _get(path; token = "")
    headers = String[]
    isempty(token) || push!(headers, "Authorization" => "Bearer $token")
    return HTTP.get("$API$path", headers)
end

@testset "tenant isolation" begin
    Storage.connect()

    # alice 与 bob 各注册
    alice = JSON.parse(String(HTTP.post("$API/api/register";
        body = JSON.json(Dict("email" => "alice@example.com"))).body))
    bob = JSON.parse(String(HTTP.post("$API/api/register";
        body = JSON.json(Dict("email" => "bob@example.com"))).body))

    # alice 创建实验 + job
    exp = JSON.parse(String(_post("/api/experiments",
        Dict("name" => "alice-exp", "config" => Dict("constellation" => "walker48"));
        token = alice["token"]).body))
    job = JSON.parse(String(_post("/api/experiments/$(exp["id"])/jobs",
        Dict(); token = alice["token"]).body))

    # bob 尝试访问 alice 的实验 → 404（隔离）
    bob_get_exp = _get("/api/experiments/$(exp["id"])"; token = bob["token"])
    @test bob_get_exp.status == 404

    # bob 尝试访问 alice 的 job → 404（隔离）
    bob_get_job = _get("/api/jobs/$(job["id"])"; token = bob["token"])
    @test bob_get_job.status == 404

    # bob 列表只能看到自己的（空）
    bob_jobs = JSON.parse(String(_get("/api/jobs"; token = bob["token"]).body))
    @test isempty(bob_jobs)

    # alice 列表能看到自己的
    alice_jobs = JSON.parse(String(_get("/api/jobs"; token = alice["token"]).body))
    @test any(j["id"] == job["id"] for j in alice_jobs)
end
