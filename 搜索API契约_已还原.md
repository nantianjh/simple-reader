# Simple 搜索 API 契约（最终版 · 已实测验证）

> 2026-09-13 验证通过 ｜ 契约来源：官方 Web 端 `main.dart.js` 静态还原 + 真实请求实测
> 本目录配套客户端：`simple_search.py`

---

## 一、核心契约

| 项 | 值 |
| --- | --- |
| API 基址 | `https://simple.imsummer.cn/` |
| **有效版本** | **`api/v3/`** |
| 鉴权 | 请求头 `Authorization: <JWT>`，**裸 token、无 `Bearer` 前缀** |
| 请求签名 | **无**（不需要任何计算头） |
| 方法 | GET + 查询串 |
| 分页 | **游标式**：`last_id` = 上一页最后一条的 `id`；首页传**空串** |
| 响应 | **裸 JSON 数组**（无 `code`/`data` 包裹），按 `created_at` 倒序 |

### ⚠️ 重要：不要用 api/v2

Web 端 `main.dart.js` 里全是 `api/v2/`（160 处），但那是**旧版构建**——
实测 `GET /api/v2/posts/search` 会**建立连接后 0 字节挂起**（60 秒超时），
而同请求改用 `api/v3` 立即返回 200。

证据：同一 token、同一批请求头下
- `GET /api/v2/posts/search?q=test&per_page=10&last_id=` → 挂起 60s，0 字节
- `GET /api/v3/posts/search?q=test&per_page=10&last_id=` → **200，9622 字节，1.8s**

原因：网页版没有搜索入口，这段 v2 搜索代码在 Web 构建里是**死代码**，
服务端已把搜索迁移到 v3。App 端（`libapp.so`）用的正是 v3。

---

## 二、请求头（来自浏览器真实请求，原样带上）

| 头 | 值 | 说明 |
| --- | --- | --- |
| `Authorization` | `eyJhbGciOiJIUzI1NiJ9...` | **必须**。JWT（HS256），payload 含 `user_id` 与 `exp` |
| `appVersionCode` | `2` | |
| `appVersionName` | `1.0.0` | |
| `channel` | `web` | |
| `countryCode` | `CN` | |
| `end` | `web` | |
| `languageCode` | `zh` | |
| `os` | `3` | |
| `Referer` | `https://simple.imsummer.cn/web` | 建议带上 |
| `User-Agent` | 浏览器 UA | **务必保持**（见第六节） |
| `Accept: */*`、`Accept-Language: zh` | | |

JWT payload 示例：`{"user_id":"15e75816-…","exp":1791887006}`
**有效期约 30 天**，过期返回 401。

---

## 三、搜索接口清单

| kind | 路径 | 说明 | 验证状态 |
| --- | --- | --- | --- |
| `posts` | `GET /api/v3/posts/search` | **全站内容搜索（主接口）** | ✅ 已实测 200 |
| `mine` | `GET /api/v3/posts/mine/search` | 我的内容 | 同构，未单独验证 |
| `channels` | `GET /api/v3/posts/channels/all/search` | 全频道内容 | 同构，未单独验证 |
| `root_channels` | `GET /api/v3/root_channels/search` | **频道搜索** | ✅ 已实测 200 |
| `tags` | `GET /api/v3/tags/search` | 标签搜索 | 未验证 |

### 请求参数

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `q` | string | **搜索关键词**（不是 `keyword`） |
| `per_page` | string | 每页条数，官方 Web 端固定传 `"10"` |
| `last_id` | string | 游标。首页传**空串** `last_id=`；翻页传上一页最后一条的 `id` |

示例（首页）：

```
GET /api/v3/posts/search?q=生活&per_page=10&last_id=
```

---

## 四、响应结构

裸数组，每页 `per_page` 条。内容帖对象共 **22 个字段**：

```
id, is_timed_post, visibility, is_pinned, comments_count, post_type,
comment_permission, created_at, post_collection_id,
is_collection_pinned, is_thanked, show_type, content,
media, is_voted, user, is_owner, is_show, is_reviewing, post_collection
```

关键字段示例：

```jsonc
{
  "id": "22cc5674-16d4-4d1b-9d31-a14a16e5802a",     // ★ 翻页游标
  "created_at": "2026-09-10T23:15:39.927588+08:00",  // 倒序排列依据
  "content": "大学的last暑假😿62 看来是昨天…",
  "post_type": "public_post",
  "visibility": "public_visibility",
  "comments_count": 0,
  "show_type": "normal",
  "user": {                       // 作者
    "id": "b61f8ff5-728a-4abc-80f6-c3f81294760f",
    "nickname": "小狗吃堡堡",
    "gender": "female",
    "avatar_url": "…", "avatar_color": "dacff7",
    "is_official": false, "is_privacy_enabled": false, "is_new_user": false
  },
  "media": [ { "url": "…", "type": "…", "width": 1080, "height": 1440 } ],
  "post_collection": {            // 所属合集（可能为 null）
    "id": "0d18cb20-…", "name": "校园生活✉️ᗪᗩIᒪY",
    "visibility": "public_visibility", "user_id": "b61f8ff5-…"
  }
}
```

频道对象（`root_channels`）字段不同：

```
id, name, icon, description, channel_members_count, creator, invite_code
```

---

## 五、客户端使用

```bash
# 全站内容搜索（默认）
python simple_search.py 生活

# 翻 3 页，保存原始 JSON
python simple_search.py 生活 --pages 3 --json out.json

# 频道搜索
python simple_search.py 摄影 --kind root_channels

# 指定 token（也可用环境变量 SIMPLE_TOKEN 或同目录 token.txt）
python simple_search.py 生活 --token eyJhbGciOi...
```

- `token.txt` 已生成在同目录（含你的 token，**注意保密，不要提交到 git**）
- 翻页间隔内置 1.2 秒限速
- 401 时脚本会提示重新取 token

---

## 六、风控与注意事项

| 项 | 说明 |
| --- | --- |
| 出口 IP | `simple.imsummer.cn` 走 Clash `cn_domain` → **DIRECT**，与你日常用 App 同一真实国内 IP，无"境外机房 IP"特征 |
| 已验证行为 | 同 token、同请求头下，`/posts/followings` 0.8s 返回 200；`/api/v3/posts/search` 1.8s 返回 200。说明正常客户端指纹是放行的 |
| ⚠️ UA 影响 | 带**浏览器 UA** 的请求正常返回。**自建客户端请保持这个 UA**，换成 `python-requests/x` 之类的 UA 有被区别对待的风险（v2 搜索对异常请求的表现就是无限挂起） |
| 频率 | 单线程串行 + 每页间隔 ≥1s；不要并发、不要循环全量抓取 |
| `/auths` | **不要**用脚本去碰登录接口（风控最敏感），token 到期就手动重新登录网页版取一次 |
| token 保密 | `token.txt` 等同于你的账号凭证，不要分享、不要入库 |

---

## 七、本轮网络请求总量（透明披露）

验证过程共向 `simple.imsummer.cn` 发起 **6 次**带凭证请求：
1×`posts/search`(v2, 挂起)、1×`posts/followings`、1×`posts/search`(v3)、
2×`root_channels/search`、1×`configs`。全部为你自己账号的正常读操作，无写操作、无登录尝试。

---

## 八、文件清单

| 文件 | 说明 |
| --- | --- |
| `simple_search.py` | **搜索客户端（可交付）** |
| `token.txt` | 你的 token（敏感） |
| `web/main.dart.js` | 官方 Web 端 JS 包（契约还原来源） |
| `search_v3.json` | 内容帖搜索原始响应样本 |
| `channels_sample.json` | 频道搜索原始响应样本 |
| `apk/simple-1.9.26-base.apk` | App 端 APK |
| `apk/endpoints_all.txt` | App 端 197 个接口清单 |
