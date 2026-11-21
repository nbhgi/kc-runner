# ============================================================
#  文件名：scripts/gate.gd
#  挂在：scenes/gate.tscn 的 Gate 节点
#  干什么：卡密门。启动第一件事——没有有效卡密就进不了游戏
# ============================================================
extends Node2D

# ---------- 【要改的地方】只改这两行 ----------
const API      := "https://你的Worker域名.workers.dev"  # 换成你部署后的地址
const SIGN_KEY := "换成你自己定的一串随机字符"            # 必须和 Worker 后台的 SIGN_KEY 一致
# ------------------------------------------------

var _dev := ""        # 本机设备码
var _busy := false    # 防止连点多次发请求

# ------------------------------------------------------------
#  _ready()：节点进场景时自动调用一次（Godot 的生命周期函数）
#  这里干的事：搭界面、读存档、有缓存就直接放行
# ------------------------------------------------------------
func _ready() -> void:
	_dev = _device_id()          # 取本机设备码
	_build_ui()                  # 用代码把界面搭出来（不用编辑器拖）
	var t := _load_token()       # 读上次激活成功的凭证
	if t != null:
		_enter_game()            # 凭证还在 → 直接进游戏（离线也能玩）

# ============================================================
#  搭界面
#  【知识点】为什么用代码建界面？
#    1) 手机 Godot 拖动控件很别扭，代码写坐标更准
#    2) 你能在同一处看到「每个按钮长什么样 + 点了干什么」
# ------------------------------------------------------------
func _build_ui() -> void:
	# 背景：一块铺满全屏的深色方块
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.12)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# 标题
	var title := Label.new()
	title.text = "KC Runner"
	title.position = Vector2(240, 300)
	title.add_theme_font_size_override("font_size", 56)
	add_child(title)

	# 输入框（场景里已经放了一个，这里再补一个按钮和提示）
	var input := $CardInput
	input.text = ""

	# 登录按钮
	var btn := Button.new()
	btn.text = "激活并进入"
	btn.position = Vector2(240, 660)
	btn.size = Vector2(240, 64)
	# 【知识点】信号连接：按钮按下时调用 _on_login
	#   等价于「事件监听器」。connect 把信号和函数绑在一起。
	btn.pressed.connect(_on_login)
	add_child(btn)

# ------------------------------------------------------------
#  点「激活并进入」
# ------------------------------------------------------------
func _on_login() -> void:
	if _busy:
		return
	var card := $CardInput.text.strip_edges().toUpperCase()
	if card.length() < 10:
		_tip("卡密格式不对")
		return
	_busy = true
	_tip("验证中…")
	# 拼请求地址：API + /verify?card=xxx&dev=设备码
	var qs := "/verify?card=" + card.uri_encode() + "&dev=" + _dev.uri_encode()
	# HTTPRequest 的 request 完成后会发 request_completed 信号
	$HTTP.request_completed.connect(_on_http_done, CONNECT_ONE_SHOT)
	$HTTP.request(API + qs)

# ------------------------------------------------------------
#  网络回调
#  【知识点】await / 信号：网络请求是「过一会儿才有结果」，
#            不能等它，所以要「注册一个函数，等它回来再跑」。
# ------------------------------------------------------------
func _on_http_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	if result != OK or code != 200:
		_tip("网络异常，检查地址或联网状态")
		return
	# 解析服务器返回的 JSON
	var data = JSON.parse_string(body.get_string_from_utf8())
	if data == null or not data.has("ok"):
		_tip("服务器返回异常")
		return
	if not data["ok"]:
		_tip(str(data.get("err", "验证失败")))
		return
	# 【关键】校验签名：用同样的密钥重算一遍，防止有人改返回值
	var msg := $CardInput.text.strip_edges().toUpperCase() + "|" + str(data["exp"]) + "|" + _dev
	if data["sig"] != _sign(msg):
		_tip("签名校验失败，结果可能被篡改")
		return
	# 通过 → 存凭证 → 进游戏
	_save_token({ "exp": data["exp"], "sig": data["sig"], "card": $CardInput.text.strip_edges().toUpperCase() })
	_enter_game()

# ------------------------------------------------------------
#  进入游戏：切换场景
# ------------------------------------------------------------
func _enter_game() -> void:
	get_tree().change_scene_to_file("res://scenes/runner.tscn")

# ============================================================
#  设备码
#  【知识点】OS.get_unique_id() 在安卓上拿设备唯一标识；
#            其他平台拿不到就用「启动时随机生成的串」兜底。
# ------------------------------------------------------------
func _device_id() -> String:
	var id := OS.get_unique_id()
	if id == "":
		var f := FileAccess.open("user://kc_dev.txt", FileAccess.READ)
		if f != null:
			id = f.get_as_text().strip_edges()
			f.close()
		else:
			id = str(RandomNumberGenerator.new().randi())
			var w := FileAccess.open("user://kc_dev.txt", FileAccess.WRITE)
			w.store_string(id)
			w.close()
	return id.sha256_text()   # 做一次哈希，不存明文

# ------------------------------------------------------------
#  HMAC-SHA256 签名（和 worker.js 里那套完全对应）
# ------------------------------------------------------------
func _sign(msg: String) -> String:
	var ctx := HMACContext.new()
	ctx.start(HashingContext.HASH_SHA256, SIGN_KEY.to_utf8_buffer())
	ctx.update(msg.to_utf8_buffer())
	return ctx.finish().hex_encode()

# ============================================================
#  本地存档：user:// 是手机上的私有目录，卸载才没
# ------------------------------------------------------------
func _save_token(d: Dictionary) -> void:
	var f := FileAccess.open("user://kc_token.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()

func _load_token() -> Dictionary:
	const P := "user://kc_token.json"
	if not FileAccess.file_exists(P):
		return {}
	var f := FileAccess.open(P, FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if d is Dictionary and d.has("exp") and int(d["exp"]) > Time.get_unix_time_from_system() * 1000:
		return d
	return {}

# ------------------------------------------------------------
#  提示文字
# ------------------------------------------------------------
func _tip(t: String) -> void:
	$Tip.text = t
