// ============================================================
// GameBootstrap.cs — 沙盒总控：WS 连接、消息路由、播放控制
// ============================================================
//
// 这是唯一需要手动挂到场景 GameObject 上的脚本。
// 它会自动创建 SimClient / SandboxWorld / SandboxUI。
//
// 流程：
//   1. 连 Julia 服务 → 请求 list_constellations → 填充下拉框
//   2. 用户选星座点 Start → 发 start_simulation
//   3. 收到响应后，服务端推 frame → 解析并渲染
//   4. SpeedSlider 控制本地播放倍率（缓冲帧）
//   5. Stop 断开连接并停止播放
// ============================================================

using System;
using System.Collections.Generic;
using UnityEngine;

public class GameBootstrap : MonoBehaviour
{
    [Tooltip("Julia 服务 WebSocket 地址")]
    public string ServerUri = "ws://127.0.0.1:8080";

    SimClient _client;
    SandboxWorld _world;
    SandboxUI _ui;

    string _sessionId;
    int _nSat;
    int _nTotal;
    float _serverFps = 10f;
    float _speed = 1f;
    bool _running;
    bool _gotFirstFrame;

    int[] _islA;
    int[] _islB;

    struct Frame
    {
        public double[] positions;
        public bool[] islAvail;
    }

    readonly Queue<Frame> _buffer = new Queue<Frame>();
    float _accum;
    int _displayedFrame;

    void Start()
    {
        // 1. 初始化单例客户端
        _client = SimClient.Instance;
        _client.OnOpen += OnClientOpen;
        _client.OnMessage += OnClientMessage;

        // 2. 创建世界与 UI（纯代码生成）
        var worldGo = new GameObject("SandboxWorld");
        worldGo.transform.SetParent(transform, false);
        _world = worldGo.AddComponent<SandboxWorld>();

        var uiGo = new GameObject("SandboxUI");
        uiGo.transform.SetParent(transform, false);
        _ui = uiGo.AddComponent<SandboxUI>();
        _ui.OnStartClicked += StartSimulation;
        _ui.OnStopClicked += StopSimulation;
        _ui.OnSpeedChanged += v => _speed = v;

        // 3. 连接
        _client.Connect(ServerUri);
        _ui.SetStatus("Connecting…");
    }

    void OnDestroy()
    {
        if (_client == null) return;
        _client.OnOpen -= OnClientOpen;
        _client.OnMessage -= OnClientMessage;
        _client.Disconnect();
    }

    // ── WS 生命周期 ───────────────────────────────────────────

    void OnClientOpen()
    {
        _ui.SetStatus("Connected");
        RequestListConstellations();
    }

    void OnClientMessage(string json)
    {
        var msg = MiniJson.Deserialize(json) as Dictionary<string, object>;
        if (msg == null) return;

        string type = msg.GetString("type");
        switch (type)
        {
            case "list_constellations_response": HandleListResponse(msg); break;
            case "describe_constellation_response": HandleDescribeResponse(msg); break;
            case "start_simulation_response": HandleStartResponse(msg); break;
            case "frame": HandleFrame(msg); break;
            case "stream_end": HandleStreamEnd(); break;
            case "error": _ui.SetStatus($"Error: {msg.GetString("message")}"); break;
            default: Debug.Log($"[GameBootstrap] unhandled msg: {type}"); break;
        }
    }

    // ── 请求发送 ──────────────────────────────────────────────

    void RequestListConstellations()
        => _client.Send("{\"type\":\"list_constellations\"}");

    void RequestDescribeConstellation(string name)
        => _client.Send($"{{\"type\":\"describe_constellation\",\"name\":\"{name}\"}}");

    void StartSimulation(string name)
    {
        if (_running) return;
        ResetSession();
        _running = true;
        _ui.SetStatus("Starting…");

        // 默认参数；服务端有默认值，这里显式传便于 Unity 端知道预期
        var req = $"{{\"type\":\"start_simulation\",\"name\":\"{name}\",\"tspan\":[0.0,600.0],\"step_s\":10.0,\"propagator\":\"j2\",\"fps\":10.0}}";
        _client.Send(req);
    }

    void StopSimulation()
    {
        if (!_running) return;
        _running = false;
        _ui.SetStatus("Stopped");
        _client.Disconnect();
        _buffer.Clear();
    }

    // ── 响应处理 ──────────────────────────────────────────────

    void HandleListResponse(Dictionary<string, object> msg)
    {
        var list = msg.GetList("names");
        var names = new string[list.Count];
        for (int i = 0; i < list.Count; i++) names[i] = list[i] as string ?? "";
        _ui.SetConstellationList(names);
        _ui.SetStatus($"{names.Length} constellations");
    }

    void HandleDescribeResponse(Dictionary<string, object> msg)
    {
        int t = msg.GetInt("T");
        int p = msg.GetInt("P");
        int f = msg.GetInt("F");
        double alt = msg.GetDouble("alt_km");
        double inc = msg.GetDouble("inc_deg");
        _ui.SetStatus($"T={t} P={p} F={f} alt={alt:F0}km inc={inc:F1}°");
    }

    void HandleStartResponse(Dictionary<string, object> msg)
    {
        _sessionId = msg.GetString("session_id");
        _nSat = msg.GetInt("n_sat");
        _nTotal = msg.GetInt("n_time");
        _serverFps = Mathf.Max(1f, (float)msg.GetDouble("fps", 10.0));
        _gotFirstFrame = false;

        _ui.SetStatus($"Session {_sessionId} — receiving {_nTotal} frames");
        _ui.SetHud(_nSat, 0, _nTotal, 0, 0);

        if (_nSat > 200)
            Debug.LogWarning($"[GameBootstrap] {_nSat} satellites; consider ≤200 for smooth playback.");
    }

    void HandleFrame(Dictionary<string, object> msg)
    {
        var posList = msg.GetList("positions");
        var pairList = msg.GetList("isl_pairs");
        var availList = msg.GetList("isl_avail");

        // 第一次收到 frame 时才知 ISL 候选边集，用来初始化场景
        if (!_gotFirstFrame)
        {
            _islA = new int[pairList.Count];
            _islB = new int[pairList.Count];
            for (int k = 0; k < pairList.Count; k++)
            {
                var pair = pairList[k] as List<object>;
                _islA[k] = Convert.ToInt32(pair[0]);
                _islB[k] = Convert.ToInt32(pair[1]);
            }
            _world.Init(_nSat, _islA, _islB);
            _gotFirstFrame = true;
        }

        var frame = new Frame
        {
            positions = ToDoubleArray(posList),
            islAvail = ToBoolArray(availList),
        };
        _buffer.Enqueue(frame);

        int frameIndex = msg.GetInt("frame_index");
        int availCount = CountTrue(frame.islAvail);
        _ui.SetHud(_nSat, frameIndex, _nTotal, availCount, _islA.Length);
    }

    void HandleStreamEnd()
    {
        _running = false;
        _ui.SetRunning(false);
        _ui.SetStatus("Stream ended");
    }

    // ── 本地播放 ──────────────────────────────────────────────

    void Update()
    {
        if (!_running || _buffer.Count == 0 || _speed <= 0f || !_world.IsInitialised) return;

        _accum += Time.unscaledDeltaTime * _speed;
        float interval = 1f / _serverFps;

        while (_accum >= interval && _buffer.Count > 0)
        {
            _accum -= interval;
            Frame frame = _buffer.Dequeue();
            _world.UpdateFrame(frame.positions, frame.islAvail);
            _displayedFrame++;
            _ui.SetHud(_nSat, _displayedFrame, _nTotal, CountTrue(frame.islAvail), _islA.Length);
        }
    }

    // ── 工具 ──────────────────────────────────────────────────

    void ResetSession()
    {
        _sessionId = null;
        _buffer.Clear();
        _accum = 0f;
        _displayedFrame = 0;
        _gotFirstFrame = false;
    }

    static double[] ToDoubleArray(List<object> list)
    {
        var a = new double[list.Count];
        for (int i = 0; i < list.Count; i++) a[i] = Convert.ToDouble(list[i]);
        return a;
    }

    static bool[] ToBoolArray(List<object> list)
    {
        var a = new bool[list.Count];
        for (int i = 0; i < list.Count; i++)
            if (list[i] is bool b) a[i] = b;
        return a;
    }

    static int CountTrue(bool[] arr)
    {
        int n = 0;
        for (int i = 0; i < arr.Length; i++) if (arr[i]) n++;
        return n;
    }
}
