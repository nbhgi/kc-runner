// ============================================================
//  文件名：worker.js
//  部署到：Cloudflare Workers（云端运行，不在手机上跑）
//  干什么：卡密服务。发卡、验卡、设备绑定、防篡改签名
//  依赖：一个 KV 命名空间，绑定名必须叫 CARDS
//        （Workers 后台 → 设置 → 绑定 → KV → 变量名填 CARDS）
// ============================================================

// 【知识点】环境变量
// 在 Workers 后台「设置 → 变量」里配置，代码里通过 env.XXX 读取。
// 不要把密钥直接写死在代码里，否则推到 GitHub 就泄露了。
//   SIGN_KEY  用来给卡密结果签名（HMAC-SHA256 的密钥）
//   ADMIN_KEY 发卡时要带的口令，防止别人乱发卡

// ---------- 工具：把字符串转成 Uint8Array（加密接口要这个格式）----------
function bytes(s) { return new TextEncoder().encode(s); }

// ---------- 工具：HMAC-SHA256 签名 ----------
// 【知识点】为什么要签名？
//   服务器返回 {"ok":true} 时，如果只靠客户端自己判断，
//   有人改一行代码把 false 改成 true 就破解了。
//   所以服务器用只有自己知道的 SIGN_KEY 对结果算一个签名，
//   客户端用同一个密钥重算一遍比对——对不上就说明被改过。
async function sign(key, msg) {
  const k = await crypto.subtle.importKey(
    'utf8', bytes(key),
    { name: 'HMAC', hash: 'SHA-256' }, // 算法：HMAC + SHA256
    false, ['sign']
  );
  const sig = await crypto.subtle.sign('HMAC', k, bytes(msg));
  // 二进制转十六进制字符串，方便塞进 JSON 里传
  return [...new Uint8Array(sig)].map(b => b.toString(16).padStart(2, '0')).join('');
}

// ---------- 工具：生成随机卡号 ----------
// 格式：KC3D1-XXXX-XXXX-XXXX
function genCard() {
  const c = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // 去掉了容易看混的 0/O/I/1
  let s = '';
  for (let i = 0; i < 12; i++) {
    if (i > 0 && i % 4 === 0) s += '-';
    s += c[Math.floor(Math.random() * c.length)];
  }
  return 'KC3D1-' + s;
}

// ---------- 主入口：所有请求都从 fetch 进 ----------
export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const path = url.pathname;

    // 【知识点】跨域头（CORS）
    // 手机浏览器 / Godot 的 HTTPRequest 请求别的域名时，
    // 浏览器会先发一个 OPTIONS「预检」，服务器必须回允许的头，
    // 否则请求直接被拦掉。所以每个响应都带上这几个头。
    const H = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
                'Access-Control-Allow-Headers': 'Content-Type' };
    if (req.method === 'OPTIONS') return new Response('', { status: 204, headers: H });

    // ===== 接口 1：发卡 =====
    // 用法：GET /gen?key=管理员口令&days=30
    if (path === '/gen') {
      if (url.searchParams.get('key') !== env.ADMIN_KEY)
        return new Response('{"ok":false,"err":"bad key"}', { status: 403, headers: H });
      const days = parseFloat(url.searchParams.get('days') || '30');
      const card = genCard();
      const rec = {                       // 这张卡的档案
        exp: Date.now() + days * 864e5,   // 到期时间（毫秒时间戳）
        dev: '',                          // 绑定的设备码，空=还没绑定
        used: 0                           // 使用次数
      };
      // 【知识点】KV 存储：Cloudflare 的键值数据库，异步读写
      await env.CARDS.put('card:' + card, JSON.stringify(rec));
      return new Response(JSON.stringify({ ok: true, card: card, days: days }), { headers: H });
    }

    // ===== 接口 2：验证卡密 =====
    // 用法：GET /verify?card=卡号&dev=设备码
    if (path === '/verify') {
      const card = (url.searchParams.get('card') || '').trim().toUpperCase();
      const dev  = (url.searchParams.get('dev')  || '').trim();
      if (!card || !dev)
        return new Response('{"ok":false,"err":"缺少参数"}', { status: 400, headers: H });

      const raw = await env.CARDS.get('card:' + card);
      if (!raw) return new Response(JSON.stringify({ ok: false, err: '卡密不存在' }), { headers: H });

      const rec = JSON.parse(raw);
      if (Date.now() > rec.exp) return new Response(JSON.stringify({ ok: false, err: '卡已过期' }), { headers: H });
      // 设备绑定：第一台设备激活后，别的设备再用同一张卡会被拒
      if (rec.dev && rec.dev !== dev) return new Response(JSON.stringify({ ok: false, err: '此卡已在其他设备激活' }), { headers: H });

      // 首次激活：写入设备码
      if (!rec.dev) { rec.dev = dev; rec.used = 1; await env.CARDS.put('card:' + card, JSON.stringify(rec)); }

      // 算签名：把「卡号 + 到期时间 + 设备码」串起来签，客户端会原样校验
      const msg = card + '|' + rec.exp + '|' + dev;
      const sig = await sign(env.SIGN_KEY, msg);
      return new Response(JSON.stringify({ ok: true, exp: rec.exp, sig: sig }), { headers: H });
    }

    // ===== 其他路径：返回说明 =====
    return new Response(JSON.stringify({ ok: true, service: 'KC Runner 卡密服务',
      apis: ['/gen?key=ADMIN_KEY&days=30', '/verify?card=KC3D1-XXXX-XXXX-XXXX&dev=设备码'] }), { headers: H });
  }
};
