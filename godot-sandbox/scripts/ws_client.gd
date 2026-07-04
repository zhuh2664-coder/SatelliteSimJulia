extends Node
# ============================================================
# ws_client.gd — WebSocket 客户端（手动实现 RFC 6455）
# ============================================================
#
# 原因：Godot 4.3 stable 这个 binary 不含 WebSocketClient 类
# （只有基类 WebSocketPeer），所以用 StreamPeerTCP 手动实现
# WS 握手 + frame 解析。客户端发出去的 frame 必须 mask。
#
# 用法：
#   WsClient.connect_to("ws://127.0.0.1:8080")
#   WsClient.connected.connect(_on_open)
#   WsClient.message_received.connect(_on_msg)  # utf-8 文本
#   WsClient.closed.connect(_on_close)
#   WsClient.send_text('{"type":"list_constellations"}')
#   WsClient.close()
# ============================================================

signal connected
signal message_received(json_text: String)
signal closed

enum State { DISCONNECTED, CONNECTING, OPEN, CLOSING }

const WS_GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

var _tcp: StreamPeerTCP
var _state: int = State.DISCONNECTED
var _host: String = ""
var _port: int = 0
var _path: String = "/"
var _inbox: PackedByteArray = PackedByteArray()
var _handshake_buf: PackedByteArray = PackedByteArray()
var _was_connected: bool = false

func _process(_delta: float) -> void:
	if _tcp == null:
		return
	match _state:
		State.CONNECTING:
			_tcp.poll()
			var s = _tcp.get_status()
			if s == StreamPeerTCP.STATUS_CONNECTED:
				_send_handshake()
				_state = State.OPEN
			elif s == StreamPeerTCP.STATUS_ERROR:
				_fail()
		State.OPEN:
			_tcp.poll()
			_drain()
		State.CLOSING:
			_tcp.poll()
			# 等服务端回应 close；这里简化直接关
			_fail()

func connect_to(uri: String) -> Error:
	if _state != State.DISCONNECTED:
		return ERR_BUSY
	# 解析 ws://host:port/path
	var scheme := ""
	var rest := ""
	if uri.begins_with("ws://"):
		scheme = "ws"
		rest = uri.substr(5)
	elif uri.begins_with("wss://"):
		push_error("wss:// not supported in this minimal client")
		return ERR_UNAVAILABLE
	else:
		return FAILED
	var path_idx = rest.find("/")
	var hostport: String
	if path_idx >= 0:
		hostport = rest.substr(0, path_idx)
		_path = rest.substr(path_idx)
	else:
		hostport = rest
		_path = "/"
	var colon = hostport.find(":")
	if colon >= 0:
		_host = hostport.substr(0, colon)
		_port = int(hostport.substr(colon + 1))
	else:
		_host = hostport
		_port = 80

	_tcp = StreamPeerTCP.new()
	var err = _tcp.connect_to_host(_host, _port)
	if err != OK:
		_tcp = null
		return err
	_state = State.CONNECTING
	_inbox = PackedByteArray()
	_handshake_buf = PackedByteArray()
	return OK

func send_text(text: String) -> Error:
	if _state != State.OPEN:
		push_warning("WsClient: send while not open")
		return ERR_UNAVAILABLE
	var payload = text.to_utf8_buffer()
	var frame = _build_frame(0x1, payload)  # 0x1 = text
	_tcp.put_data(frame)
	return OK

func close() -> void:
	if _state == State.DISCONNECTED:
		return
	_state = State.CLOSING

func is_open() -> bool:
	return _state == State.OPEN

# ── 握手 ──────────────────────────────────────────────────

func _send_handshake() -> void:
	# 生成 16 字节随机 key
	var key_bytes = PackedByteArray()
	key_bytes.resize(16)
	for i in 16:
		key_bytes[i] = randi() % 256
	var key_b64 = Marshalls.raw_to_base64(key_bytes)
	var req = "GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % [_path, _host, _port, key_b64]
	_tcp.put_data(req.to_utf8_buffer())

func _drain() -> void:
	var avail = _tcp.get_available_bytes()
	if avail <= 0:
		return
	var chunk = _tcp.get_data(avail)
	if chunk[0] != OK:
		return
	var bytes: PackedByteArray = chunk[1]
	if _state == State.OPEN and _was_connected == false:
		# 仍可能在收握手响应（OPEN 表示已发出 handshake，未必收完 101）
		_handshake_buf.append_array(bytes)
		var end = _find_subseq(_handshake_buf, "\r\n\r\n".to_utf8_buffer())
		if end < 0:
			return
		var head = _handshake_buf.slice(0, end)
		var head_str = head.get_string_from_utf8()
		if head_str.begins_with("HTTP/1.1 101"):
			_was_connected = true
			connected.emit()
			# 把剩余字节（handshake 后跟着的 frame）推入 inbox
			var rest = _handshake_buf.slice(end + 4)
			if rest.size() > 0:
				_inbox.append_array(rest)
		else:
			push_error("WS handshake failed: " + head_str.substr(0, 80))
			_fail()
			return
	elif _was_connected:
		_inbox.append_array(bytes)

	# 解析 inbox 中的 WS frames
	while true:
		var parsed = _try_parse_frame()
		if parsed.is_empty():
			break
		# opcode 0x1 = text, 0x2 = binary
		if parsed.opcode == 0x1:
			message_received.emit(parsed.payload.get_string_from_utf8())
		elif parsed.opcode == 0x8:
			# close
			_state = State.CLOSING
			_fail()
			return
		# 其它 opcode 暂忽略

# ── Frame 解析（服务端 → 客户端，unmasked） ──────────────

func _try_parse_frame() -> Dictionary:
	# 最小 header 2 字节
	if _inbox.size() < 2:
		return {}
	var b1 = _inbox[0]
	var b2 = _inbox[1]
	var fin = (b1 & 0x80) != 0
	var opcode = b1 & 0x0F
	var masked = (b2 & 0x80) != 0
	var len7 = b2 & 0x7F
	var offset = 2
	var payload_len: int
	if len7 < 126:
		payload_len = len7
	elif len7 == 126:
		if _inbox.size() < offset + 2:
			return {}
		payload_len = (_inbox[offset] << 8) | _inbox[offset + 1]
		offset += 2
	else:  # 127
		if _inbox.size() < offset + 8:
			return {}
		payload_len = 0
		for i in 8:
			payload_len = (payload_len << 8) | _inbox[offset + i]
		offset += 8
	if masked:
		if _inbox.size() < offset + 4:
			return {}
		offset += 4
	if _inbox.size() < offset + payload_len:
		return {}
	var payload = _inbox.slice(offset, offset + payload_len)
	_inbox = _inbox.slice(offset + payload_len)
	fin  # unused but referenced
	return {"opcode": opcode, "payload": payload}

# ── Frame 构造（客户端 → 服务端，必须 mask） ──────────────

func _build_frame(opcode: int, payload: PackedByteArray) -> PackedByteArray:
	var mask_key = PackedByteArray()
	mask_key.resize(4)
	for i in 4:
		mask_key[i] = randi() % 256
	var n = payload.size()
	var header = PackedByteArray()
	header.append(0x80 | (opcode & 0x0F))  # FIN=1
	if n < 126:
		header.append(0x80 | n)            # MASK=1
	elif n <= 0xFFFF:
		header.append(0x80 | 126)
		header.append((n >> 8) & 0xFF)
		header.append(n & 0xFF)
	else:
		header.append(0x80 | 127)
		for i in range(7, -1, -1):
			header.append((n >> (i * 8)) & 0xFF)
	# mask payload
	var masked = PackedByteArray()
	masked.resize(n)
	for i in n:
		masked[i] = payload[i] ^ mask_key[i % 4]
	return header + mask_key + masked

# ── 关闭 ──────────────────────────────────────────────────

func _fail() -> void:
	_tcp = null
	_state = State.DISCONNECTED
	if _was_connected:
		_was_connected = false
		closed.emit()

# 在 haystack 中找 needle 子序列，返回起始下标，未找到 -1
func _find_subseq(haystack: PackedByteArray, needle: PackedByteArray) -> int:
	if needle.size() == 0:
		return 0
	var h = haystack.size()
	var n = needle.size()
	for i in (h - n + 1):
		var found = true
		for j in n:
			if haystack[i + j] != needle[j]:
				found = false
				break
		if found:
			return i
	return -1
