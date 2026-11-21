# ============================================================
#  文件名：scripts/runner.gd
#  挂在：scenes/runner.tscn 的 Runner 节点
#  干什么：地铁跑酷式三轨跑酷的全部玩法
#         三轨 = 左 / 中 / 右 三条道；左右切道，上跳，下滑铲
# ============================================================
extends Node3D

# ---------- 【可调参数】想改难度就改这几个数字 ----------
const LANES := [-2.2, 0.0, 2.2]   # 三条道的 X 坐标
const START_SPEED := 14.0          # 初始前进速度（米/秒）
const MAX_SPEED := 30.0            # 速度上限
const SPEED_UP := 0.35             # 每秒加速多少
const GRAVITY := 42.0              # 重力，越大掉得越快
const JUMP_V := 15.0               # 起跳初速度
const SEG_LEN := 40.0              # 每段跑道长度
const SEG_COUNT := 6               # 同时保留的跑道段数（循环复用）
# ----------------------------------------------------------

var speed := START_SPEED           # 当前速度
var score := 0.0                   # 分数
var best := 0                      # 最高分（本地存档）
var lane := 1                      # 当前轨道：0左 1中 2右
var vel_y := 0.0                   # 竖直速度
var sliding := false               # 是否滑铲中
var slide_timer := 0.0             # 滑铲剩余时间
var alive := true                  # 是否存活
var player: CharacterBody3D        # 玩家节点
var segments := []                 # 跑道段数组（对象池）
var obstacles := []                # 障碍数组（对象池）
var spawn_z := 0.0                 # 下一个障碍的 Z 位置

# ---------- 生命周期：进场景跑一次 ----------
func _ready() -> void:
	player = $Player
	_load_best()
	_build_world()
	_spawn_all()

# ---------- 生命周期：每帧跑一次。delta = 距上一帧秒数 ----------
func _process(delta: float) -> void:
	if alive:
		_handle_input()
		_tick_run(delta)
	_update_hud()

# ============================================================
#  输入
#  【知识点】is_action_just_pressed = 「这一帧刚按下」，只触发一次
# ------------------------------------------------------------
func _handle_input() -> void:
	if Input.is_action_just_pressed("ui_left")  or _take_swipe(1): _change_lane(-1)
	if Input.is_action_just_pressed("ui_right") or _take_swipe(2): _change_lane(1)
	if Input.is_action_just_pressed("ui_up")    or _take_swipe(3): _jump()
	if Input.is_action_just_pressed("ui_down")  or _take_swipe(4): _slide()

# ------------------------------------------------------------
#  触屏滑动识别
#  原理：手指按下记起点，松开算位移，够大就判定方向
# ------------------------------------------------------------
var _touch_start := Vector2.ZERO
var _swipe_dir := 0                # 1左 2右 3上 4下

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_start = event.position
			# 点左半边/右半边也能切道（给不想滑动的玩家）
			if event.position.x < 360: _change_lane(-1)
			elif event.position.x > 360: _change_lane(1)
		else:
			var d := event.position - _touch_start
			if abs(d.x) > 60 and abs(d.x) > abs(d.y):
				_swipe_dir = 1 if d.x < 0 else 2
			elif d.y < -60: _swipe_dir = 3
			elif d.y > 60:  _swipe_dir = 4

# 一次滑动只被消费一次
func _take_swipe(want: int) -> bool:
	if _swipe_dir == want:
		_swipe_dir = 0
		return true
	return false

# ------------------------------------------------------------
#  切道：用 tween 做平滑横移
#  【知识点】tween = 让某个值在一段时间内从 A 变到 B
# ------------------------------------------------------------
func _change_lane(dir: int) -> void:
	lane = clampi(lane + dir, 0, LANES.size() - 1)
	create_tween().tween_property(player, "position:x", LANES[lane], 0.12)

func _jump() -> void:
	if player.position.y <= 1.01:   # y=1 是地面
		vel_y = JUMP_V
		sliding = false

func _slide() -> void:
	if sliding or player.position.y > 1.01:
		return
	sliding = true
	slide_timer = 0.6
	player.get_node("Mesh").scale = Vector3(1, 0.4, 1)   # 压扁表示蹲下

# ============================================================
#  每帧逻辑
# ------------------------------------------------------------
func _tick_run(delta: float) -> void:
	speed = minf(speed + SPEED_UP * delta, MAX_SPEED)
	score += speed * delta * 0.1

	# 重力与落地
	vel_y -= GRAVITY * delta
	var p := player.position
	p.y += vel_y * delta
	if p.y <= 1.0:
		p.y = 1.0
		vel_y = 0.0
	player.position = p

	# 滑铲计时
	if sliding:
		slide_timer -= delta
		if slide_timer <= 0.0:
			sliding = false
			player.get_node("Mesh").scale = Vector3(1, 1, 1)

	# 跑道往后走（玩家原地跑，世界移动 = 跑酷游戏通用做法）
	for s in segments:
		s.position.z += speed * delta
		if s.position.z > SEG_LEN * 1.5:
			s.position.z -= SEG_LEN * SEG_COUNT   # 挪回队尾，循环

	# 障碍移动 + 碰撞
	for o in obstacles:
		o.position.z += speed * delta
		if o.visible and _hit(o):
			o.visible = false
			_die()
		if o.position.z > 12:
			o.visible = false

	# 持续生成
	spawn_z -= speed * delta
	if spawn_z < -SEG_LEN * (SEG_COUNT - 1):
		_spawn_row()

# ------------------------------------------------------------
#  碰撞判断：不同道直接放行；同道具看距离；高低障碍看姿态
# ------------------------------------------------------------
func _hit(o: Node3D) -> bool:
	if abs(o.position.x - player.position.x) > 0.9: return false
	if abs(o.position.z - player.position.z) > 0.9: return false
	if o.name == "Low"  and sliding:                 return false   # 低障碍 + 滑铲 = 躲过
	if o.name == "High" and player.position.y > 1.5: return false  # 高障碍 + 跳 = 躲过
	return true

# ------------------------------------------------------------
#  死亡 → 结算 → 点一下重来
# ------------------------------------------------------------
func _die() -> void:
	alive = false
	if score > best:
		best = int(score)
		_save_best()
	var ui := Control.new()
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.6)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.add_child(bg)
	var tip := Label.new()
	tip.text = "撞到了！得分 %d\n最高 %d\n点击重来" % [score, best]
	tip.position = Vector2(160, 400)
	tip.size = Vector2(400, 120)
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ui.add_child(tip)
	var retry := ColorRect.new()
	retry.color = Color(0, 0, 0, 0)
	retry.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	retry.gui_input.connect(func(e):
		if e is InputEventScreenTouch and e.pressed:
			get_tree().reload_current_scene())
	ui.add_child(retry)
	add_child(ui)

# ============================================================
#  建世界
#  【知识点】对象池：障碍不反复 new/free，提前造好一批循环用，
#            手机上不卡、不产生内存垃圾。
# ------------------------------------------------------------
func _build_world() -> void:
	var i := 0
	while i < SEG_COUNT:
		var seg := StaticBody3D.new()
		var ground := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(8, 0.4, SEG_LEN)
		ground.mesh = box
		seg.add_child(ground)
		seg.position = Vector3(0, 0, -i * SEG_LEN)
		add_child(seg)
		segments.append(seg)
		# 每个位置造一个高障碍和一个低障碍，先隐藏
		for kind in ["High", "Low"]:
			var o := StaticBody3D.new()
			o.name = kind
			var m := MeshInstance3D.new()
			var ob := BoxMesh.new()
			ob.size = Vector3(1.2, 1.6 if kind == "High" else 0.7, 1.2)
			m.mesh = ob
			m.position.y = 0.8 if kind == "High" else 0.35
			o.add_child(m)
			o.visible = false
			add_child(o)
			obstacles.append(o)
		i += 1
	spawn_z = -20.0

func _spawn_row() -> void:
	for o in obstacles:
		if not o.visible:
			o.position = Vector3(LANES[randi() % LANES.size()], 1.0, spawn_z)
			o.visible = true
			break

func _spawn_all() -> void:
	var i := 0
	while i < SEG_COUNT - 1:
		_spawn_row()
		i += 1

# ------------------------------------------------------------
#  HUD：分数浮在 3D 画面上
#  【知识点】CanvasLayer 让 2D 界面始终盖在 3D 画面之上
# ------------------------------------------------------------
var _hud: Label
func _update_hud() -> void:
	if _hud == null:
		_hud = Label.new()
		_hud.position = Vector2(24, 40)
		_hud.add_theme_font_size_override("font_size", 30)
		var c := CanvasLayer.new()
		c.add_child(_hud)
		add_child(c)
	_hud.text = "得分 %d   最高 %d" % [int(score), best]

# ------------------------------------------------------------
#  最高分存档
# ------------------------------------------------------------
func _load_best() -> void:
	const P := "user://kc_best.json"
	if FileAccess.file_exists(P):
		var f := FileAccess.open(P, FileAccess.READ)
		var d := JSON.parse_string(f.get_as_text())
		if d and d.has("best"): best = int(d["best"])
		f.close()

func _save_best() -> void:
	var f := FileAccess.open("user://kc_best.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({ "best": best }))
	f.close()
