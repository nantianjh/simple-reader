# 应用内登录（WebView 直取 token）可行性 - 探查报告

> 问题：用自建 Web 桥后，能否在应用内直接完成网页登录，不跳浏览器？
> 调查对象：`https://simple.imsummer.cn/web`（官方 Web 端，Flutter Web）
> 方法：下载并静态分析其编译产物 `main.dart.js`（4,338,115 B）与 `flutter_bootstrap.js`，**全程只读静态资源，未请求任何登录/鉴权接口**。
> 日期：2026-09-17

---

## 结论

**可以。** 全程不出应用、不需要电脑、不需要开发者工具。机制如下：

```
应用内 WebView 打开官方 Web 端
  → 用户手动完成手机号 + 短信验证码登录（真实浏览器内核，与用浏览器登录同源）
  → 前端把用户信息整体写入 localStorage["flutter.UserInfo"]
  → 原生侧 evaluateJavascript 读出该 JSON，取其中的 token 字段
  → 经 MethodChannel 回传 Flutter，走既有的 parseJwt 校验 + TokenStore 保存链路
```

体积代价 ≈ 0（系统 WebView，不打包浏览器内核）。并且条件比预想更好：**Web 端是 dart2js + HTML renderer，不依赖 gstatic 的 CanvasKit CDN**，嵌入式 WebView 内不存在被墙导致白屏的风险。

---

## 一、证据链（逐环节可复核）

| # | 环节 | 结论 | 产物中的证据 |
|---|---|---|---|
| 1 | Web 端形态 | Flutter Web，dart2js 编译，**renderer = html** | `flutter_bootstrap.js` 末尾：`_flutter.buildConfig = {"engineRevision":"a18df97ca…","builds":[{"compileTarget":"dart2js","renderer":"html","mainJsPath":"main.dart.js"}]}` |
| 2 | 登录方式 | 手机号 + 短信验证码为主；另支持微信 | `api/v2/phone_messages/deliveries`（发码）、`api/v2/phone_messages/verifications`（校验）、`api/v2/auths`（登录，含 `provider:"wechat"/uid/token` 的微信分支） |
| 3 | 凭证持久化机制 | shared_preferences 的 Web 实现 → **localStorage，键名统一加 `flutter.` 前缀** | `A.Ex.prototype.dj(a,b,c){ … return $.bBG().tL(a,"flutter."+b,c) }`；`tL` → `self.window.localStorage.setItem(b, …)`；getAll 用 `new A.aKX(new A.b5w("flutter.",null))` 过滤前缀 |
| 4 | 实际写入的键 | **`flutter.UserInfo`**、`flutter.USER_TOKEN_REFRESH` | `$.cj.bQ().dj("String","UserInfo", r)`；`$.cj.bQ().dj("String","USER_TOKEN_REFRESH", this.a)` |
| 5 | **App 需要的 token 字段** | **`token`**（不是 `auth_token`） | `A.b3W(A.at(["Authorization", A.bj().gnC()], …))` —— Authorization 头取 `gnC()`；`gnC` 对应序列化键 `"token"`（`q.l(0,"token",r.gnC())`），而 `"auth_token"` 对应的是另一个 getter `gHV()` |
| 6 | 下次打开免登录 | 启动时从 SharedPreferences 读回 `UserInfo` 反序列化 | `c2h(){ … s=A.df("UserInfo"); q=B.J.rE(0, s==null?"":s, null); $.ts=A.bBp(q) … }` |
| 7 | token 生命周期 | 约 30 天（本地可解析 `exp`）；Web 端**每天**首次打开会调 `api/v2/refresh_token` 刷新并写回 localStorage | `USER_TOKEN_REFRESH` 存日期串，`if(日期 !== 存储值) → POST api/v2/refresh_token`；响应 `token` 非空则覆盖 `UserInfo.token` 并重设 Authorization |

> 第 5 条是最容易踩错的地方：`UserInfo` 里**同时**有 `token` 和 `auth_token` 两个字段，仅看字段名会误判。必须以「Authorization 头的取值表达式」为准。

---

## 二、落地设计

### 2.1 原生侧（与上一轮《内建浏览器方案》同一个 `BrowserActivity`）

```java
// WebSettings：两项必需
settings.setJavaScriptEnabled(true);     // Dart2JS 产物必须
settings.setDomStorageEnabled(true);     // localStorage 必须（读取 token 的前提）
settings.setUserAgentString(uaWithoutWv); // 去掉默认 UA 里的 "; wv" 标记

// 登录成功后读取（只读，不注入任何可被页面调用的桥）
webView.evaluateJavascript(
    "(function(){try{return localStorage.getItem('flutter.UserInfo')||''}catch(e){return ''}})()",
    value -> { /* value 是被 JSON 转义的字符串，先反转义再解析，取 token 字段 */ });
```

触发时机建议**叠加三层**，从稳到自动：

| 层 | 方式 | 特点 |
|---|---|---|
| a | 顶部条加「我已完成登录」按钮，用户点击后读取 | 最稳、零自动化，完全符合契约风控要求 |
| b | `onPageFinished` 后每 1.5 s 轮询一次，最多 20 次 | 自动；只读操作，不触碰任何接口 |
| c | `shouldOverrideUrlLoading` 检测到从登录页跳走时触发一次 | 减少等待 |

取到后通过 MethodChannel 回传：`system` 通道新增 `awaitAuth`（或独立的 `auth` 通道），携带 `{token, raw}`。

### 2.2 Dart 侧

- `NativeBridge` 新增 `openLoginWeb()` 与 `onAuthToken` 回调；
- `token_setup_page.dart:219-226` 的「账号登录」从**禁用态改为可用**（当前文案为「方案搁置，暂未开放」）；
- 拿到 token 后**复用既有链路**：`parseJwt` 预检 → `app.loginWithToken(text)`（`token_setup_page.dart:92`）→ `TokenStore.write`，不做第二条路径；
- 字段兜底算法：

```
u = JSON.parse(localStorage['flutter.UserInfo'])
候选 = [u.token, u.auth_token].filter(非空)
选第一个 parseJwt 成功且未过期的；全部不合格则报错并留在登录页
```

### 2.3 与既有计划的衔接

- `api_config.dart:70-71` 的备忘录（分享链接后期改为内置浏览器访问）与本方案同源：**同一个 `BrowserActivity` 既能承载登录，也能打开分享页**，只需多传一个「读取 token」的开关参数。
- `token_setup_page.dart:12-13` 注释中「账号登录按需求搁置」——本方案即该需求的落地路径，无需新增依赖。

---

## 三、风险与边界

| # | 风险 | 说明 | 处置 |
|---|---|---|---|
| 1 | 契约红线：`/auths` 风控最敏感，不得用脚本碰 | WebView 内是**真人手动登录**，与用户自己用浏览器登录同源，不触线 | 严格零自动化：不代填手机号、不自动提交、不自动触发「发送验证码」 |
| 2 | 微信登录在 WebView 内基本不可用 | `provider:"wechat"` 那条路依赖微信环境 | 只引导手机号 + 短信验证码路径；微信入口在应用内隐藏或提示去浏览器 |
| 3 | 每日 refresh 可能作废旧 token | Web 端每天首次打开会调 `api/v2/refresh_token` 并覆盖 `UserInfo.token`。若服务端发新废旧，App 里的 token 会随之失效 | **并非本方案新增的风险**——现状手工复制的 token 同样如此。缓解：401 时提供「重新登录」一键回到 WebView 登录页（`api_client.dart:198` 的提示文案同步更新） |
| 4 | WebView 登录态与 App 的 token 是两套 | WebView 的 localStorage 在应用私有目录长期留存 | 退出登录时同步清理：`CookieManager.removeAllCookies()` + `WebStorage.getInstance().deleteAllData()` |
| 5 | 默认 UA 带 `; wv` 标记 | 可能被识别为嵌入式环境 | 设置为普通浏览器 UA（去掉 `wv`） |
| 6 | 安全 | 网页内容不可信 | 不用 `addJavascriptInterface`（只用 `evaluateJavascript` 主动读）；`setAllowFileAccess(false)`、`setAllowContentAccess(false)`；限制导航域名，站外链接交给系统浏览器 |
| 7 | Service Worker 缓存 | 站点注册了 SW（`serviceWorkerVersion: "2781218723"`），发版后可能停在旧缓存 | 出现异常时清 WebView 站点数据；必要时用 `ServiceWorkerController` 放行/拦截 |

---

## 四、待实测项（3 条，真机一次即可跑通）

1. **WebView 内渲染**：手机号登录页在系统 WebView（HTML renderer）下的实际表现——渲染、输入、短信倒计时。
2. **键名运行时确认**：登录后执行一次 `localStorage.getItem('flutter.UserInfo')`，确认键名与 `token` 字段非空（静态分析已给出高置信推断，但仍应实测一次）。
3. **refresh 语义**：`api/v2/refresh_token` 是「延长同一 token」还是「发新废旧」——决定 App 内 token 的真实有效语义与是否需要跟随刷新。

---

## 附录：本次探查所用的可复现步骤

产物留档目录：`analysis/`

| 文件 | 用途 |
|---|---|
| `probe_web_token.py` / `..2.py` | 抓首页 → 定位 `flutter_bootstrap.js` → 找入口 bundle |
| `probe_web_token3.py` | 下载 `main.dart.js` 并搜索 `localStorage` / `flutter.` / `auths` |
| `probe_web_token4.py` | 枚举全部含 `token`/`auth` 的字符串常量（定位键名与字段名） |
| `probe_web_token5.py` | 确认 `Authorization` 头取值表达式与 `UserInfo` 落盘点 |
| `probe_engine_config.py` | 读取 `_flutter.buildConfig`，判定渲染器与外部 CDN 依赖 |

> 结论均可由任一人重新下载同一 bundle 复核（`engineRevision: a18df97ca57a249df5d8d68cd0820600223ce262`）。
