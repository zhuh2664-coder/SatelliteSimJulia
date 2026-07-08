using Test
using SatelliteSimLab

@testset "AI agent hooks" begin
    SatelliteSimLab.clear_hooks!()
    provider = SatelliteSimLab.LLMProvider(; key = "dummy")
    agent = SatelliteSimLab.SimAgent(provider)

    SatelliteSimLab.register_hook!(:pre_llm) do ctx
        return :block
    end
    @test SatelliteSimLab.run_agent(agent, "hello") == "（被 pre_llm 钩子阻断）"

    SatelliteSimLab.clear_hooks!()
    msg = SatelliteSimLab.AssistantMessage("old", SatelliteSimLab.ToolCall[])
    replacement = SatelliteSimLab.AssistantMessage("new", SatelliteSimLab.ToolCall[])
    SatelliteSimLab.register_hook!(:post_llm) do ctx, value
        return replacement
    end
    _, transformed = SatelliteSimLab.run_hooks!(:post_llm, SatelliteSimLab.PostLLMCtx(msg, agent))
    @test transformed === replacement

    SatelliteSimLab.clear_hooks!()
    SatelliteSimLab.ensure_default_hooks!()
    long = repeat("x", SatelliteSimLab.DEFAULT_TRUNCATE_CHARS + 10)
    out = SatelliteSimLab.default_truncation_hook(
        SatelliteSimLab.PostToolCtx("dummy", Dict{String,Any}(), long, agent),
        long,
    )
    @test endswith(out, "...(截断)")
end
