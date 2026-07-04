extends Node
# 注：autoload 名 "WsClient" 与 class_name 会冲突，所以不加 class_name
# 全局通过 /root/WsClient 访问
# ============================================================
# WsClient.gd — WebSocketPeer 封装（Godot 4 内置）
# ============================================================
#
# 单例 Autoload，挂在 /root/WsClient。
# 用法：
#   WsClient.connect_to("ws://127.0.0.1:8080")
#   WsClient.connected.connect(_on_open)
#   WsClient.message_received.connect(_on_msg)
#   WsClient.closed.connect(_on_close)
#   WsClient.send_text('{"type":"list_constellations"}')
#
# Godot 4 WebSocketPeer 是同步轮询模型，必须在 _process 里调 poll()。
# ============================================================

signal connected
signal message_received(json_text: String)
signal closed

var _peer: WebSocketPeer
var _was_connected: bool = false

func _process(_delta: float) -> void:
	if _peer == null:
		return
	_peer.poll()
	var state = _peer.get_ready_state()
	match state:
		WebSocketPeer.STATE_OPEN:
			if not _was_connected:
				_was_connected = true
				connected.emit()
			while _peer.get_available_packet_count() > 0:
				var pkt = _peer.get_packet()
				message_received.emit(pkt.get_string_from_utf8())
		WebSocketPeer.STATE_CLOSING:
			_peer.close()
		WebSocketPeer.STATE_CLOSED:
			_peer = null
			if _was_connected:
				_was_connected = false
				closed.emit()

func connect_to(uri: String) -> Error:
	if _peer != null:
		return ERR_BUSY
	# 解析 ws://host:port/path
	var scheme := ""
	var rest := ""
	if uri.begins_with("ws://"):
		scheme = "ws"
		rest = uri.substr(5)
	elif uri.begins_with("wss://"):
		scheme = "wss"
		rest = uri.substr(6)
	else:
		return FAILED
	var path_idx = rest.find("/")
	var hostport: String
	if path_idx >= 0:
		hostport = rest.substr(0, path_idx)
	else:
		hostport = rest
	var colon = hostport.find(":")
	var host: String
	var port: int
	if colon >= 0:
		host = hostport.substr(0, colon)
		port = int(hostport.substr(colon + 1))
	else:
		host = hostport
		port = 80
		if scheme == "wss":
			port = 443

	_peer = WebSocketClient.new()
	var err = _peer.connect_to_url(uri)
	if err != OK:
		_peer = null
	return err

func send_text(text: String) -> Error:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("WsClient: send while not connected")
		return ERR_UNAVAILABLE
	return _peer.put_packet(text.to_utf8_buffer())

func close() -> void:
	if _peer != null:
		_peer.close()

func is_open() -> bool:
	return _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN
