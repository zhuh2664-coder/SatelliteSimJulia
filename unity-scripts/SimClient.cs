// ============================================================
// SimClient.cs — WebSocket 客户端（System.Net.WebSockets 内置）
// ============================================================
//
// 用 .NET 自带的 ClientWebSocket，避免 NativeWebSocket 在
// macOS Editor 下的兼容问题。跨平台稳定，无需第三方包。
//
// 用法：
//   SimClient.Connect("ws://127.0.0.1:8080");
//   SimClient.OnOpen += () => Debug.Log("connected");
//   SimClient.OnMessage += json => Debug.Log(json);
//   SimClient.Send("""{"type":"list_constellations"}""");
// ============================================================

using System;
using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using UnityEngine;

public class SimClient : MonoBehaviour
{
    static SimClient _instance;
    public static SimClient Instance
    {
        get
        {
            if (_instance == null)
            {
                var go = new GameObject("SimClient");
                _instance = go.AddComponent<SimClient>();
                DontDestroyOnLoad(go);
            }
            return _instance;
        }
    }

    public event Action OnOpen;
    public event Action<string> OnMessage;

    ClientWebSocket _ws;
    CancellationTokenSource _cts;
    Task _runner;
    readonly ConcurrentQueue<string> _inbox = new ConcurrentQueue<string>();

    public bool IsConnected => _ws != null && _ws.State == WebSocketState.Open;

    public void Connect(string uri)
    {
        if (_ws != null) return;
        _ws = new ClientWebSocket();
        _cts = new CancellationTokenSource();
        var token = _cts.Token;
        _runner = Task.Run(() => RunSession(uri, token));
    }

    async Task RunSession(string uri, CancellationToken token)
    {
        try
        {
            await _ws.ConnectAsync(new Uri(uri), token);
            _inbox.Enqueue("__OPEN__");
            var buf = new byte[64 * 1024];
            while (_ws.State == WebSocketState.Open && !token.IsCancellationRequested)
            {
                var result = await _ws.ReceiveAsync(new ArraySegment<byte>(buf), token);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    try { await _ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "", token); }
                    catch { /* best effort */ }
                    break;
                }
                _inbox.Enqueue(Encoding.UTF8.GetString(buf, 0, result.Count));
            }
        }
        catch (OperationCanceledException) { /* disconnect */ }
        catch (Exception e)
        {
            _inbox.Enqueue("__ERR__:" + e.Message);
        }
        finally
        {
            _inbox.Enqueue("__CLOSE__");
        }
    }

    public async void Send(string json)
    {
        if (!IsConnected)
        {
            Debug.LogWarning("[SimClient] Send while not connected: " + json);
            return;
        }
        try
        {
            var bytes = Encoding.UTF8.GetBytes(json);
            await _ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, _cts.Token);
        }
        catch (Exception e)
        {
            Debug.LogError("[SimClient] Send failed: " + e.Message);
        }
    }

    public void Disconnect()
    {
        if (_ws == null) return;
        try { _cts?.Cancel(); } catch { }
        try
        {
            if (_ws.State == WebSocketState.Open)
                _ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None);
        }
        catch { /* best effort */ }
        _ws = null;
    }

    void Update()
    {
        while (_inbox.TryDequeue(out var msg))
        {
            if (msg == "__OPEN__") { OnOpen?.Invoke(); continue; }
            if (msg == "__CLOSE__") { _ws = null; continue; }
            if (msg.StartsWith("__ERR__:"))
            {
                Debug.LogError("[SimClient] " + msg.Substring(8));
                continue;
            }
            try { OnMessage?.Invoke(msg); }
            catch (Exception e) { Debug.LogError("[SimClient] OnMessage handler threw: " + e); }
        }
    }

    void OnDestroy() => Disconnect();
}
