# KC Runner —— 地铁跑酷式三轨跑酷（Godot 4）+ 卡密验证

## 一、仓库里都是什么
```
worker.js           卡密服务端（部署到 Cloudflare Workers）
wrangler.toml       Worker 部署配置（网页部署可忽略）
project.godot       Godot 工程设置（竖屏、省电渲染）
scenes/gate.tscn    启动场景：卡密门
scenes/runner.tscn  游戏场景：相机 + 光 + 玩家
scripts/gate.gd     卡密验证逻辑（逐行中文注释）
scripts/runner.gd   跑酷玩法逻辑（逐行中文注释）
export_presets.cfg  安卓 APK 导出预设
.gitignore
README.md           你正在看的这个文件
```

## 二、怎么学习（照这个顺序读代码）
1. **worker.js** —— 看懂「为什么卡密要放云端」和「HMAC 签名防的是什么」
2. **scripts/gate.gd** —— 学会：代码建界面、HTTPRequest 发请求、信号 connect、本地存档
3. **scripts/runner.gd** —— 学会：_ready/_process 生命周期、触屏滑动、对象池、碰撞分层判断

## 三、部署卡密服务（Cloudflare，免费额度够用）
1. 注册 https://dash.cloudflare.com → 左侧「Workers 和 Pages」→ 创建 → 从 Hello World 开始
2. 把 `worker.js` 全文粘进去，部署
3. 该 Worker →「设置 → 变量」→ 添加：
   - `SIGN_KEY` = 一串你自己的随机字符
   - `ADMIN_KEY` = 发卡口令，自己记住
4. 该 Worker →「设置 → 绑定」→ 添加 KV 命名空间，变量名填 `CARDS`
   （若还没有 KV，去「存储与数据库 → KV」新建一个再回来绑定）
5. 打开 `https://你的Worker域名/` 看到服务说明就成功了
6. 发卡：浏览器打开 `https://你的Worker域名/gen?key=你的ADMIN_KEY&days=30`
   返回 `{"ok":true,"card":"KC3D1-XXXX-XXXX-XXXX"}` 就是一张新卡

## 四、接进游戏
1. 打开 `scripts/gate.gd`，改顶部两行：
   - `API` = 你部署后的 Worker 地址
   - `SIGN_KEY` = 第三步里设的那个值（两边必须一模一样）
2. 手机上装 Godot 4（或 Godot 导出助手）→ 打开 `project.godot`
3. 点运行 → 应该先看到卡密门 → 输卡 → 进跑道 → 左/右/跳/滑铲

## 五、打包成 APK
Godot →「项目 → 导出 → Android」→ 读 `export_presets.cfg` → 导出 APK。
若手机上没有 Android Studio，用「Godot 导出助手」App 可以直接离线出包。

## 六、玩法
- 左滑 / 点左半屏 → 切到左边道
- 右滑 / 点右半屏 → 切到右边道
- 上滑 / 空格 → 跳（躲高障碍）
- 下滑 / Shift → 滑铲（钻低障碍）
- 撞到障碍扣命，点一下屏幕重来

## 七、性能说明（给低配机）
- 渲染走 `gl_compatibility`，关阴影关抗锯齿
- 跑道段和障碍都用「对象池」循环复用，不反复创建销毁
- 竖屏 720×1280，手机屏再差也能稳住
