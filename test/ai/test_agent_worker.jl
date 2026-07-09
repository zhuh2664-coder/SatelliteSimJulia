using Test
using SatelliteSimLab

function _cleanup_worker_sessions(prefix)
    base = joinpath("data", "sessions")
    isdir(base) || return nothing
    for name in readdir(base)
        startswith(name, prefix) || continue
        rm(joinpath(base, name); recursive = true, force = true)
    end
    return nothing
end

@testset "AI agent worker protocol" begin
    @testset "worker registers agent type and lazily activates sessions" begin
        prefix = "test_worker_$(rand(UInt))"
        try
            provider = SatelliteSimLab.MockProvider([
                SatelliteSimLab.AssistantMessage("planner first", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("planner second", SatelliteSimLab.ToolCall[]),
            ])
            worker = SatelliteSimLab.AgentWorker(prefix, provider)
            SatelliteSimLab.register_agent_type!(worker, "planner";
                instruction = "planner instruction",
                tool_allowlist = ["list_available"],
                session_prefix = prefix,
            )
            service = SatelliteSimLab.AgentWorkerService()
            SatelliteSimLab.register_worker!(service, worker)

            agent_id = SatelliteSimLab.AgentId("study_a", "planner")
            first = SatelliteSimLab.dispatch_agent!(service, agent_id, "first request")
            second = SatelliteSimLab.dispatch_agent!(service, agent_id, "second request")

            @test first.content == "planner first"
            @test first.activated
            @test second.content == "planner second"
            @test !second.activated
            @test length(SatelliteSimLab.active_agent_ids(worker)) == 1
            @test worker.active[agent_id].memory.session_id == "$(prefix)_study_a_planner"
            @test length(worker.active[agent_id].tools) == 1
            @test first.worker_id == prefix
            @test service.directory[agent_id] == prefix
        finally
            _cleanup_worker_sessions(prefix)
            SatelliteSimLab.clear_hooks!()
        end
    end

    @testset "namespace separates active agents with same type" begin
        prefix = "test_worker_ns_$(rand(UInt))"
        try
            provider = SatelliteSimLab.MockProvider([
                SatelliteSimLab.AssistantMessage("A", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("B", SatelliteSimLab.ToolCall[]),
            ])
            worker = SatelliteSimLab.AgentWorker(prefix, provider)
            SatelliteSimLab.register_agent_type!(worker, "runner"; session_prefix = prefix)
            service = SatelliteSimLab.AgentWorkerService()
            SatelliteSimLab.register_worker!(service, worker)

            a = SatelliteSimLab.dispatch_agent!(service, SatelliteSimLab.AgentId("ns_a", "runner"), "run")
            b = SatelliteSimLab.dispatch_agent!(service, SatelliteSimLab.AgentId("ns_b", "runner"), "run")

            @test a.activated
            @test b.activated
            @test length(SatelliteSimLab.active_agent_ids(worker)) == 2
            @test Set(agent_id.namespace for agent_id in SatelliteSimLab.active_agent_ids(worker)) == Set(["ns_a", "ns_b"])
        finally
            _cleanup_worker_sessions(prefix)
            SatelliteSimLab.clear_hooks!()
        end
    end

    @testset "event dispatch is one-way and rpc preserves request id" begin
        prefix = "test_worker_msg_$(rand(UInt))"
        try
            provider = SatelliteSimLab.MockProvider([
                SatelliteSimLab.AssistantMessage("event consumed", SatelliteSimLab.ToolCall[]),
                SatelliteSimLab.AssistantMessage("rpc reply", SatelliteSimLab.ToolCall[]),
            ])
            worker = SatelliteSimLab.AgentWorker(prefix, provider)
            SatelliteSimLab.register_agent_type!(worker, "reviewer"; session_prefix = prefix)
            service = SatelliteSimLab.AgentWorkerService()
            SatelliteSimLab.register_worker!(service, worker)

            user = SatelliteSimLab.AgentId("client", "user")
            reviewer = SatelliteSimLab.AgentId("study_msg", "reviewer")
            event = SatelliteSimLab.AgentEvent(user, reviewer, "remember this")
            @test SatelliteSimLab.dispatch_event!(service, event) === nothing

            request = SatelliteSimLab.AgentRpcRequest("req-1", user, reviewer, "review now")
            response = SatelliteSimLab.dispatch_rpc!(service, request)

            @test response.id == "req-1"
            @test response.sender == reviewer
            @test response.recipient == user
            @test response.content == "rpc reply"
            @test response.error === nothing
            @test length(SatelliteSimLab.active_agent_ids(worker)) == 1
        finally
            _cleanup_worker_sessions(prefix)
            SatelliteSimLab.clear_hooks!()
        end
    end

    @testset "service rejects unsupported agent type" begin
        service = SatelliteSimLab.AgentWorkerService()
        @test_throws ErrorException SatelliteSimLab.dispatch_agent!(service, SatelliteSimLab.AgentId("ns", "missing"), "hello")

        request = SatelliteSimLab.AgentRpcRequest(
            "req-missing",
            SatelliteSimLab.AgentId("client", "user"),
            SatelliteSimLab.AgentId("ns", "missing"),
            "hello",
        )
        response = SatelliteSimLab.dispatch_rpc!(service, request)
        @test response.id == "req-missing"
        @test response.error !== nothing
        @test occursin("no worker registered", response.error)
    end
end
