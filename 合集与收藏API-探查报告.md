# 合集与收藏 API 探查报告（官方 Web 端实测）

- 探查时间：2026-09-15
- 数据来源 A（静态）：官方 Web 端编译产物 `https://simple.imsummer.cn/web/main.dart.js`
  - 大小 4,338,115 B，md5 `7a173bf608d4deeeeb84f7a0fdc0868f`（本地副本 `.workbuddy/cache/web-bundle/main.dart.js`）
  - 入口链路：`index.html` → `flutter_bootstrap.js`（`_flutter.buildConfig.mainJsPath = "main.dart.js"`）
- 数据来源 B（动态）：浏览器内已登录会话（Tabbit 绑定 Profile）用页面内 `fetch` 实打实调用
  - 凭证只作为 `Authorization` 请求头在页面上下文内使用，**未写入任何文件**
- 被探查的分享链接：`https://simple.imsummer.cn/sharePost?id=ca0a219e-fa06-4709-b1e0-41343ddf34ff`

---

## 〇、勘误（2026-09-15 晚，比本文档其余部分新，冲突时以此节为准）

**本文档第一至八节只扫了 `api/v2/`，漏了版本维度。`api/v3/` 是同一域名下的另一套服务，
"合集"能力的真实位置在 v3。** 关键更正：

| 事项 | 一~八节的（错误）结论 | 实测更正 |
| --- | --- | --- |
| 合集对象有没有"我收藏了它"字段 | 没有（仅 `id/name/description/visibility`） | **v3 有 `is_favourited`**（还有 `user_id`） |
| 单条合集能否 GET | 不能，`/{id}` 只接 PATCH/DELETE（405） | **v3 可以：`GET api/v3/post_collections/{id}` → 200**，含 `is_favourited` + `posts_count` |
| "收藏的合集"是否存在 | 完全不存在 | **半存在**：读得到状态、写与汇总没入口（详见第九节） |
| `api/v1/` | 未探测 | 已补测：**整个 v1 空间不存在**（4 条全 34 B 通用路由 404） |

根因：官方 Web 端编译产物只引用 v2，我把它当成了"全量接口面"，而本产品的搜索走 v3
（见《搜索API契约_已还原.md》）。**同一个域名下并存多套 API 版本，必须先把版本空间扫全。**

---

## 一、结论速览

| 问题 | 结论 | 依据 |
|---|---|---|
| 是否有「收藏的合集」接口 | **半存在**：状态可读，无写入端点、无汇总端点 | 见第九节（v3 `is_favourited` 实测为 true） |
| 是否有「收藏他人的合集」接口 | **状态可读**（你已收藏了他人一个合集） | `GET api/v3/post_collections/{id}` → `is_favourited: true` |
| 能否进入**他人**合集（列表） | **可以** | `GET api/v3/post_collections?user_id=<任意 uid>` → 200，返回 8 条他人合集 |
| 能否进入**他人**合集详情（内容） | **可以** | `GET api/v2/posts/profile?user_id=<作者>&post_collection_id=<合集>` → 200，10/10 条语义匹配 |
| 是否有「单个合集」的 GET | **v3 有、v2 没有** | `api/v3/.../{id}` → 200；`api/v2/.../{id}` → 405 |

**一句话**：Simple 的「收藏」在服务端只作用于**动态**，合集不存在被收藏的语义；
但**他人合集及其内容是可读的**，进入链路是 `动态 → post_collection → 帖子列表`。

---

## 二、实测接口清单

| 方法 | 路径 | 参数 | 实测结果 |
|---|---|---|---|
| GET | `api/v2/post_collections` | `user_id`（必填，缺省 **400**） | 200；无分页参数，一次返回全部（我 7 条 / 他人 8 条） |
| PATCH | `api/v2/post_collections/{id}` | body `{name, description}` | 编译产物中确认（编辑合集） |
| POST | `api/v2/post_collections` | body `{name, description}` | 编译产物中确认（新建合集） |
| DELETE | `api/v2/post_collections/{id}` | — | 编译产物中确认 |
| PATCH | `api/v2/post_collections/sort` | — | 编译产物中确认（合集排序） |
| GET | `api/v2/posts/profile` | `user_id`（+可选 `post_collection_id`）、`last_id`、`per_page` | 200；**他人合集内容走这条** |
| GET | `api/v2/posts/mine` | `user_id`、`last_id`、`per_page`（+可选 `post_collection_id`） | 200；自己的动态 |
| GET | `api/v2/posts/{id}` | — | 200；**响应内嵌完整 `post_collection` 对象** |
| POST / DELETE | `api/v2/favourites` | body/param `post_id` | 收藏 / 取消收藏**动态** |
| GET | `api/v2/favourites` | `last_id`、`per_page` | 200；返回**动态**列表（Post 模型） |
| GET | `api/v2/posts?post_collection_id=…` | — | 200 但**参数被静默忽略**（见第四节） |

路由语义（编译产物 `A.au()` 为 baseUrl，`A.c5/A.dh/A.eE/A.fq` 分别对应 GET/POST/DELETE/PATCH）：

```
api/v2/post_collections            GET   q.l(0,"user_id", …)
api/v2/post_collections/{id}       PATCH body {name, description}
api/v2/post_collections            POST  body {name, description}
api/v2/post_collections/{id}       DELETE
api/v2/post_collections/sort       PATCH
```

---

## 三、数据模型字段（实测响应）

**PostCollection（合集）—— 只有 4 个字段：**

```json
{ "id": "39045d48-41b5-450d-a23c-800412b83a3b",
  "name": "网",
  "description": "各种有趣实用网站",
  "visibility": "public_visibility" }
```

没有 `is_favourited`、没有 `user`（作者对象）、没有计数类字段。
→ **客户端不可能靠这个模型表达"我收藏了这个合集"**，这是「收藏的合集」不存在的最直接证据。

**Post（动态）里与合集/收藏相关：**

- `post_collection_id`：所属合集 id，可为 null
- `post_collection`：**完整内嵌合集对象**（`{id,name,description,visibility}`）
- `is_favourited`：布尔，当前用户是否收藏了这条动态
- 完整字段：`id, is_timed_post, visibility, is_pinned, comments_count, post_type, comment_permission,
  created_at, post_collection_id, content, media, is_voted,
  user, is_owner, is_show, is_reviewing, post_collection`

分享链接实测（`sharePost?id=ca0a219e-…`）：

```json
{ "id": "ca0a219e-fa06-4709-b1e0-41343ddf34ff",
  "post_type": "public_post", "visibility": "public_visibility",
  "is_favourited": false,
  "post_collection_id": "39045d48-41b5-450d-a23c-800412b83a3b",
  "post_collection": { "id": "39045d48-…", "name": "网",
                       "description": "各种有趣实用网站", "visibility": "public_visibility" },
  "user": { "id": "ad5c6767-704c-4275-8780-7f29d6af3fae", "nickname": "喜" } }
```

**重要**：拿到一条动态就能同时拿到它的作者 id 和所属合集对象，**进入他人合集不需要额外请求**。

---

## 四、静默忽略陷阱（必须避免）

`post_collection_id` 只在 `/posts/profile` 与 `/posts/mine` 上生效。对 `api/v2/posts` 传该参数会被**丢弃且不报错**：

| 调用 | 返回条数 | 其中属于目标合集的条数 | 判定 |
|---|---|---|---|
| `api/v2/posts/profile?user_id=<作者>&post_collection_id=<cid>` | 10 | **10**（其余 0，distinct 仅目标 cid） | ✅ 过滤真实生效 |
| `api/v2/posts?post_collection_id=<cid>` | 10 | **0**（10 条全部不属于该合集，distinct=[]） | ❌ 参数被忽略，返回无过滤全量流 |
| `api/v2/posts/profile?user_id=<作者>`（不过滤） | 10 | 1（distinct 含 2 个不同合集） | 对照组，证明过滤前后确有差异 |
| `api/v2/posts/mine?user_id=<我>&post_collection_id=<他人合集>` | 0 | 0（`[]`） | ✅ 语义正确 |

若客户端图省事用 `api/v2/posts?post_collection_id=`，会把**整个全站动态流**当成合集内容渲染——
数据"看起来对"但完全是错的。**必须用 `posts/profile`。**

---

## 五、「收藏的合集」候选面探测（全部否定）

带真实凭证请求，404 即路由不存在（404 响应体 `{"status":404,"error":"Not Found"}`）：

| 候选 | 结果 |
|---|---|
| `api/v2/post_collections/favourites` | **405**（只是 `/{id}` 路由不接受 GET，非独立接口；同一 random uuid 亦 405） |
| `api/v2/post_collection_favourites` | 404 |
| `api/v2/favourite_post_collections` | 404 |
| `api/v2/favourites/post_collections` | 404 |
| `api/v2/favourites/collections` | 404 |
| `api/v2/favourites/collections` / `api/v2/collections` | 404 |
| `api/v2/post_collections_with_favourites` | 404 |
| `api/v2/users/{uid}/post_collections` | 404 |
| `api/v2/post_collections?user_id=<我>&favourited=true` | 200，**与不带参数完全一致**（816 B，首条 id 相同）→ 参数被忽略 |
| 同上 `&is_favourited=true` / `&type=favourite` / `&collection_type=favourite` | 同上，均被忽略 |
| `api/v2/favourites?type=post_collection` | 200，**长度与基线完全相同**（12371 B、10 条）→ 参数被忽略 |
| 同上 `&model_type=post_collection` / `&target=collection` | 同上 |

静态侧交叉验证：整个 4.34 MB 产物中，`is_favourited` 字面量只出现 2 次且都属于 Post 模型；
含 `collection` 的字段字面量只有 `post_collection_id`；不存在任何"收藏合集"相关的路径或字段。

---

## 六、附带发现：Web 端当前在这台机器上起不来

- 带 hash 的深链进入后，hash 会被应用**归一化掉**：`/web#/minified:a0J`、`/web#/sharePost?id=…` 最终都停在同一地址 `https://simple.imsummer.cn/web`
- 页面停在落地页「单纯交个朋友」+ Simple 标识，**整场不发任何 API 请求**（监听 10 s，`/api/` 命中 0 次）
- 该 Profile 的 localStorage 已持久化两条启动异常：
  - `flutter.ERROR-1`：`TypeError: Cannot read properties of null (reading 'v')` @ `main.dart.js:87945`
  - `flutter.ERROR-3`：`You are trying to use contextless navigation without a GetMaterialApp or Get.key`
    （调用栈落在登录恢复函数 `HL` 里 `A.MX(A.bLZ(),null,B.pa)` 那一步，即"恢复登录后跳主页"）
- 推测：登录态恢复后跳转主页时抛 GetX 上下文异常 → 应用停在落地页。**这是 Web 端自身的问题，与本 App 无关**，但意味着**不能靠"打开网页看它的网络请求"来还原接口**，本次接口结论全部由页面内直接 `fetch` 实测得到。

---

## 七、对客户端接入的建议

1. **进入任意（含他人）合集的完整链路**（3 步，全部已实测可用）：
   1. 有动态 id（搜索结果、分享链接、动态流）：`GET api/v2/posts/{id}` → 取 `post_collection` 与 `user.id`
   2. 展示"TA 的合集"：`GET api/v2/post_collections?user_id=<作者 id>`（无分页，一次拿全）
   3. 合集内容分页：`GET api/v2/posts/profile?user_id=<作者 id>&post_collection_id=<合集 id>&last_id=&per_page=10`
      （自己的合集用 `api/v2/posts/mine`，参数相同）
2. **不要**为合集详情单独找"单条合集接口"——不存在（405），合集对象请从列表项或动态内嵌字段取。
3. **不要**用 `api/v2/posts?post_collection_id=`——参数被静默忽略。
4. 「收藏的合集」在服务端不存在，客户端若要做该功能只能**本地自建**（本地记录 collection id + 名称 + 快照），
   且要知道：**没有任何服务端接口能告诉客户端"我收藏了哪些合集"**。
5. 收藏仍是动态专属：`POST api/v2/favourites` / `DELETE api/v2/favourites`，body/参数 `post_id`；列表 `GET api/v2/favourites?last_id=&per_page=10`。

---

## 八、补查：`#/minified:a0J` 到底是不是一个入口

起因：被问到"没查到接口，是不是因为没真正进入 `https://simple.imsummer.cn/web#/minified:a0J`"。
结论先行：**它不是路由，也不可能是"隐藏入口"的钥匙**；而"没查到"与"没进入它"无关。

### 8.1 `minified:` 是 Dart2JS 的内部符号名前缀

产物里 `minified` 只出现 **2 次**，都是同一段 Dart2JS 运行时逻辑：

```js
bTk(a){var s=v.mangledGlobalNames[a]; if(s!=null)return s; return "minified:"+a}
chv(a){var s=v.mangledGlobalNames[a]; if(s!=null)return s; return "minified:"+a}
```

`mangledGlobalNames` 命中就返回真名，否则回退 `"minified:"+<压缩后的符号名>`。
`a0J` 正是 Dart2JS 压缩标识符的形状。→ `minified:a0J` 是**某个被压缩函数的名字**，
既不是路径、不是路由、也不是参数。把它当 URL 路径拼进地址栏，属于字符串来源错位。

### 8.2 只有一份产物，不存在"另一个 minified 版本"

| 检查项 | 结果 |
| --- | --- |
| `flutter_bootstrap.js` 的 buildConfig | **只有 1 个 build**：dart2js / renderer=html / main.dart.js |
| `/web/main.dart.min.js` | **404** |
| `/web/flutter_service_worker.js` | 文件存在，但 buildConfig 无 `serviceWorkerVersion` → loader 走 `Null serviceWorker configuration. Skipping.`，**SW 实际未注册** |
| SW 资源清单里 `main.dart.js` 的指纹 | `7a173bf608d4deeeeb84f7a0fdc0868f` = **本次静态分析那份副本的 md5**（一致） |
| `/web/version.json` | `{"app_name":"simple_web","version":"1.0.0","build_number":"2"}` |

→ 静态分析的接口面 = 运行时真正加载的那份，不存在版本错位或缓存旧包。

### 8.3 应用**确实**用 hash 路由，但路由表里没有 `minified`

引擎侧是 Flutter 的 HashUrlStrategy（压缩后为 `A.aMH`），语义仍可读：

```js
aft(){var s=self.window.location.hash
      if(s.length===0||s==="#")return"/"
      return s.substring(1)}              // getPath：路径来自 location.hash
acW(a){ var r=(a.length===0||a==="/")?"":"#"+a; return pathname+search+r }  // buildUrl：'/' → 不带 #
ad6(...){ history.pushState(...) }   vR(...){ history.replaceState(...) }
RU(...){ window.addEventListener("popstate", ...) }
```

所以**地址栏 fragment 的确是路由路径的来源**——直觉方向没错。但完整路由表只有 18 条
（`A.cab()` 注册，全部小写比对）：
`/userdetailpage`、`/momentdetailpage`、`/momentnotificationpage`、`/userbadgesdetailpage`、
`/reportlistpage`、`/reportdetailpage`、`/userleveldetailpage`、`/usercreditdetailpage`、
`/usereditpage`、`/followandfriendpage`、`/channlejoinreceivelistpage`、`/homemessage`、
`/homechannel`、`/addcf`、`/joinchannel`、`/sharechannel`、`/sharepost`、`/sharefriend`
—— **没有 `minified` 这一项**（也没注册给 GetX，而是给深链分发器 `cad()`）。

且 `cad()` 在整份产物里**只有一个调用点**：插件深链流 `$.bTA().gus().i0(new A.bmQ())`，
其入口日志写的是 `"schemes方式打开 -> "`（scheme 方式，即 `simple://` 这类**操作系统级**深链），
**不是浏览器地址栏**。

### 8.4 运行时实验（直接反驳"没进去所以没查到"）

在已加载页面上依次改 hash，每次等 6–9 s：

| 设置的 hash | 读回的 `location.hash` | 期间 `/api/` 请求数 |
| --- | --- | --- |
| （基线，不动） | `""` | 0 |
| `#/minified:a0J` | `""`（被清空） | **0** |
| `#/sharePost?id=ca0a219e-…`（真实存在的路由名） | `""` | **0** |
| `#/HomeChannel`（真实存在的路由名） | `""` | **0** |

hash 立刻被清空，与 HashUrlStrategy「读到未注册路径 → 用 `replaceState` 写回当前路由 `/`」完全吻合
（`acW("/")` 生成的 URL 不带 `#`）。**连已注册的路由名都进不去**，`#/minified:a0J` 更不可能是钥匙。

### 8.5 所以：结论不依赖"进入"，但确实存在一处空白

**不依赖**的三条理由：
1. 接口面来自产物本身的全量字符串枚举，且产物指纹与运行时一致（§8.2）；
2. 存在性是**服务端路由判定**：带真实 token 请求返回的是 API 自己的 JSON 404
   `{"status":404,"error":"Not Found"}`（与站点 HTML 404「1722 B」明显不同），
   说明是 API 路由器答的"没有此路由"，不是被前端挡住的；UI 停在哪一屏不改变服务端路由表；
3. **能力性证据**：PostCollection 只有 4 个字段、`api/v2/favourites` 只认 `post_id`、
   带"类型/收藏"参数时响应逐字节不变 —— 即使某个界面画了一个"收藏合集"按钮，
   **服务端没有地方存这个状态**，功能无法成立。

**必须承认的空白**：
- 我**没能逐屏验证 UI**：这个 Web 端在本机启动即抛异常（`flutter.ERROR-1`/`ERROR-3`），
  停在落地页且全程 0 条请求（§六）。所以"某个界面里是否存在这样一个按钮"
  我无法回答；能回答的是"它背后没有服务端能力"。
- 枚举法不是穷举：本轮把候选扩到 46 条（§8.6）仍可能漏掉一个我猜不到名字的路由。

### 8.6 候选路径扩展扫描（46 条，带真实会话）

| 状态 | 条数 | 说明 |
| --- | --- | --- |
| 404 | 29 | API 路由器答 `{"status":404,"error":"Not Found"}`（34 B） |
| 405 | 8 | 全是 `api/v2/post_collections/<单词>`（bookmark/collect/favorite/favourite/follow/like/star/subscribe）→ 都是 `/{id}` 通配拒绝 GET，**不是子资源** |
| 400 | 8 | 形如 `api/v2/post_collections/?<param>=true` → 返回 `{"error":"user_id is missing"}`，命中的是**列表处理器**本身，额外参数与路由无关 |

关键否定项：
- **嵌套子资源全部 404**：`api/v2/post_collections/{cid}/posts`、`/post`、`/items`、`/moments`
  （用真实 cid 与假 uuid 结果一致）→ 没有"合集内动态"的嵌套端点，内容只能走 `api/v2/posts/profile`；
- `me/post_collections`、`my_post_collections`、`user_post_collections`、`collections/favourites`、
  `collection_favourites`、`post_collection_bookmarks` 等 → 404。

---

## 九、v3 空间实测：收藏合集"是完全没有还是不通"的最终答案

**答案：都不是。是"半存在"——读得通，写与汇总没有入口。**

### 9.1 服务端确实有"收藏合集"的能力和数据（决定性证据）

`GET api/v3/post_collections/{id}` → **200**（v2 同路径是 405），响应：

```json
{"id":"39045d48-41b5-450d-a23c-800412b83a3b","name":"网","description":"各种有趣实用网站",
 "visibility":"public_visibility","user_id":"ad5c6767-704c-4275-8780-7f29d6af3fae",
 "is_favourited":true,"posts_count":20}
```

注意 **`user_id` 是别人（ad5c6767），而 `is_favourited` 是 `true`** —— 这条记录说的是
"**当前登录用户（15e75816）收藏了这个他人的合集**"。

分布对照（同一批账号实测）：

| 对象 | 条数 | `is_favourited=true` |
| --- | --- | --- |
| 他人（ad5c6767）的 8 个合集 | 8 | **1**（「网」，= 分享动态所属合集） |
| 我自己（15e75816）的 7 个合集 | 7 | 0（自己不能收藏自己的） |

→ 结论：**存储层与读取层都存在**，服务端准确维护"我收藏了哪个他人合集"。
这不是"完全没有"。

### 9.2 但两个缺口都实打实

| 缺口 | 证据 |
| --- | --- |
| **没有"汇总我收藏的所有合集"的端点** | 11 个筛选参数在 v3 上**全部被静默忽略**（响应与基线逐字节等长 1313/1499 B）：`favourited=true`、`is_favourited=true`、`favourited=1`、`favourite=true`、`favorite=true`、`only_favourited=true`、`scope=favourited`、`filter=favourited`、`order=is_favourited`、`type=favourite`、`collection_type=favourite`；另 9 条专属命名路径（`/favourited`、`/favourite`、`/subscribed`、`/starred`、`/marked`、`/saved`、`/liked`、`/favoured`、`/collected`）全部 404。且 `/post_collections` **强制要求 `user_id`**，只能按作者逐个查 |
| **没有找到"收藏/取消收藏一个合集"的写端点** | 9 种命名的子路由全试过、全 34 B 通用路由 404：`POST|PUT|GET /{id}/favourite`、`POST /{id}/favorite|favourites|collect|star|mark|save|bookmark|like`。而 `POST|DELETE api/v3/favourites` 只认 `post_id`：传 `{post_collection_id: <fake>}` 直接回 **400 `{"error":"post_id is missing"}`**，说明它根本不看这个参数 |

**所以可用的只有"读"**：把某个作者的合集列表拉回来、按 `is_favourited` 自己筛出"我收藏了 TA 的哪些"。
拿不到"我收藏的全部合集"（跨作者），也无法主动添加/取消。

### 9.3 判别"完全没有 vs 不通"的方法（本题的核心）

这套服务端对两种 404 给了**可区分的响应体**，这就是判别钥匙：

| 响应 | 长度 | 含义 |
| --- | --- | --- |
| `{"status":404,"error":"Not Found"}` | 34 B | **通用路由 404 → 路由不存在** |
| `{"code":404,"message":"Translation missing: zh-CN.errors.postcollection.not_found","debug_info":""}` | 99 B | **命中了 `/post_collections/{id}` 路由**，只是资源不存在 → **路由存在** |
| `{"code":404,"message":"Translation missing: zh-CN.errors.post.not_found",...}` | 89 B | 命中 `/favourites` 路由，post 不存在 → **路由存在** |

推论：
- 我探过的写入候选**全部是 34 B**，即"路由不存在"——**不是"被挡住/不通"**。
  若为"存在但调用失败"，应出现 401 / 403 / 405 / 422 之类可区分应答，而不是清一色路由级 404。
- 反过来，`/post_collections/{id}` 与 `/favourites` 都给出了 99/89 B 的"资源不存在"，
  证明**路由匹配层工作正常**，"全站统一伪装 404"的假设不成立。
- 顺带暴露技术栈：错误文案形如 `Translation missing: zh-CN.errors.*`，是 **Rails 的 i18n 缺翻译**。

### 9.4 残余不确定（不粉饰）

写端点的名字若落在我枚举的集合之外，它的表现**同样是 34 B 通用 404，与"不存在"不可区分**。
所以准确表述是：**在我枚举的命名集合内（约 80 条路径 / 参数），不存在合集的写入端点与汇总端点**。
另有一种无法排除的可能：官方 App 走了一个更特殊的命名或另一个前缀；`api/v1/` 已排除（全 404），
`api/v2/`、`api/v3/` 已扫。

### 9.5 对客户端的直接结论

合集相关应**从 v2 切到 v3**（v2 缺字段、缺单条 GET）：

| 能力 | v2 | v3 |
| --- | --- | --- |
| 合集列表 `?user_id=` | 200，字段 `id/name/description/visibility` | 200，**多出 `user_id` 与 `is_favourited`** |
| 单条合集 `/{id}` GET | **405** | **200**（含 `is_favourited` + `posts_count`） |
| 收藏状态展示 | 拿不到 | **可以展示"这个合集我已收藏"** |
| 收藏/取消收藏合集 | 无 | **无**（未发现写端点） |
| 汇总"我收藏的所有合集" | 无 | **无**（只能按作者查后本地筛） |
| `favourites` 列表 | 动态 | 动态（v3 版本多 `is_collection_pinned`/`is_thanked`/`show_type` 等字段） |

### 9.6 补测："我收藏的合集"能不能当列表拿到？——不能，且已把这条路封死

**① `user_id` 的语义是"合集作者"，不是"收藏人"。** 传特殊值一律走到"找不到该用户"分支：

| 参数 | 结果 |
| --- | --- |
| `?user_id=me` / `self` / `current_user` / `0` / 空 | 404 **89 B** `errors.user.not_found`（路由命中、用户不存在）→ 无"当前用户"简写 |

**② 19 个"收藏关系"参数全部被忽略。** 除第 9.2 节的 11 个外，再补 8 个：
`favourite_user_id`、`favourited_by`、`collector_id`、`who_favourited`、`favourite_of`、
`with_favourite`、`is_favourited=1`、`favourited_only=1` → 全部 200 / 1313 B / n=7，与基线逐字节一致。

**③ 用 A/B/A 交错排除了"列表自身在变"的干扰**（此前观测到 15860 / 16264 / 14281 三种长度，
一度疑似参数生效）：

| 请求 | 长度 | 条数 | 首条 id |
| --- | --- | --- | --- |
| baseline | 14281 | 10 | `d7d1ada2-…` |
| `&model=post_collection` | 14281 | 10 | `d7d1ada2-…` |
| baseline（再） | 14281 | 10 | `d7d1ada2-…` |
| `&model=post_collection`（再） | 14281 | 10 | `d7d1ada2-…` |
| baseline（三次） | 14281 | 10 | `d7d1ada2-…` |
| `&zzz_nonsense=1`（无意义参数对照） | 14281 | 10 | `d7d1ada2-…` |

→ 连无意义参数的返回都逐字节相同 ⇒ **参数确实被丢弃**，先前的长度差异是列表内容随时间漂移。
（`target_type=post_collection` 同样 14281。）

**④ `api/v3/favourites` 结构上给不出合集。** 它的返回项是 **Post**（keys 含
`is_timed_post`/`post_type`/`comments_count`），任何参数都不改变这一点 ⇒ 即使参数生效，
也只会是"筛动态"，不可能返回合集对象。

**⑤ 7 条"我的收藏"风格路径**（`/me/favourites`、`/current_user/favourites`、
`/current_user/post_collections`、`/current_user/favourite_post_collections`、
`/favourites/post_collections`…）→ 全 **34 B 通用路由 404**。

**⑥ 顺带查清单条合集路由的方法集**（无 body 或假 id，未改动任何真实数据）：
`GET` ✅ / `PUT` ✅（99 B 资源不存在式 404 = 路由存在）/ `DELETE` ✅ / `POST` 405 / `PATCH` 405。
且 `PUT` 打在**他人合集**（真实存在的 id）上同样返回"资源不存在" ⇒ **写操作的查找范围限定在自己名下**。
这反过来说明：若存在"收藏他人合集"的写端点，它必须跨越这个范围限制，而所有候选命名全是路由级 404。

**结论（可直接引用）**：
- "我收藏的合集"作为**一份完整列表** → **拿不到**（没有任何端点能按"收藏人"维度列合集；
  只能按作者查再本地筛，而作者维度无法穷举，等于做不到）。
- "某个合集我是否收藏了" / "某作者的合集里我收藏了哪些" → **拿得到**（`is_favourited`）。
- 客户端若要做"我的收藏夹"，**只能本地自建**：收藏动作在自己客户端里落地（本地存
  collection id + 名称 + 作者 + 快照），或在浏览他人主页时把 `is_favourited=true` 的项
  累积进本地库。代价是：用户在**官方 App/网页**里收藏的合集，你的客户端**无从得知其 id**
  （除非又恰好翻到那个作者），本地库天然不完整。

---

## 十、他人动态 → 进入其合集 → 看全部动态：**可行，且已做完整性校验**

### 10.1 完整链路（三步，全部实测）

```
① 拿到一条动态（搜索结果 / 分享链接 / 动态流 / 收藏列表）
   → 响应里已内嵌 post_collection{id,name,description,visibility}
   → 同时拿到作者 user.id
② 合集头部（名称/简介/总数/我是否收藏）
   GET api/v3/post_collections/{collection_id}
   → 200 {…, "user_id":"<作者>", "is_favourited":bool, "posts_count":20}
③ 合集内动态（游标分页）
   GET api/v2/posts/profile?user_id=<作者id>&post_collection_id=<合集id>
       &last_id=<游标>&per_page=10
```

### 10.2 完整性校验：拿到 20 条 = 合集声明的 `posts_count` 20

对被测合集（`39045d48-…`「网」，`posts_count: 20`）翻到耗尽：

| 页 | HTTP | 条数 | 首条 id |
| --- | --- | --- | --- |
| 第 1 页 | 200 | 10 | `44df1e3b-…` |
| 第 2 页 | 200 | 10 | `99d745ac-…` |
| 第 3 页 | 200 | **0**（终止） | — |

**合计 20 条，去重后仍 20 条** ⇒ 分页**不重不漏**，且与合集对象的权威计数
`posts_count: 20` **完全吻合** ⇒ **能看到该合集的全部动态**。

对照实验（同一作者、不加合集过滤）：前 10 条里混入了 **2 个不同合集**
（`cids = [39045d48…, da92d6ed…]`）⇒ 过滤参数确实在生效，不是"返回恰好都是它"的巧合。

### 10.3 三个必须知道的细节

**① `per_page` 不是范围限制，是白名单**（实测）：

| `per_page` | 结果 |
| --- | --- |
| 10 | 200，返回 10 条 |
| 20 | 200，返回 20 条 |
| **21 / 30** | 200，但**只返回 20 条** |
| **50 / 100** | **400** `{"error":"per_page does not have a valid value"}` |

→ 客户端固定用 **10**（或 20），**不要超过 30**，否则直接 400。

**② 合集内的顺序不是时间倒序。** 第 1 页 10 条的 `created_at` 实测为：
`2026-08-12, 2026-09-14, 2026-09-12, 2026-09-11, 2026-08-13, 2025-12-23, 2025-09-28,
2025-09-04, 2025-09-02, 2025-09-02` —— 明显被打乱。
因为合集支持**自定义排序**（v2 有 `PATCH api/v2/post_collections/sort`）。
→ **客户端按服务端返回顺序渲染即可，不要自己按时间重排**，否则与官方端不一致。

**③ v2 与 v3 的 `posts/profile` 返回同一个集合，但顺序可能不同。**
两者各自翻到耗尽都是 20 条、去重 20 条，且 `v2Only=[]`、`v3Only=[]`（互为子集 ⇒ 集合相同），
但两次的 id 序列 `sameIds=false`。
→ 端点可互换，**不要跨版本假设顺序一致**。

### 10.4 返回项结构（可直接用于渲染）

`posts/profile` 的每一项是完整 Post，含
`id, is_timed_post, visibility, is_pinned, comments_count, post_type, comment_permission,
created_at, post_collection_id, content, media,
is_voted, user, is_owner, is_show, is_reviewing, post_collection`
—— 注意**内嵌 `post_collection`**，可顺手渲染"来自「网」"这类来源标签。

### 10.5 权限边界

合集的 `visibility` 实测均为 `public_visibility`；他人公开合集可读（列表 + 单条 + 内容）。
**写入**他人合集不可行：`PUT api/v2|v3/post_collections/{他人合集}` 返回"资源不存在"
（写操作查找范围限定在自己名下，见 9.6⑥）。

---

## 十一、`collection_visibility` 合集在动态里**不下发** `post_collection` 内嵌对象（2026-09-15 实测）

> **更正 10.5 的"visibility 实测均为 `public_visibility`"**：`visibility` 至少有两个取值，
> 且第二个取值会**改变动态的字段结构** —— 这不是次要细节，直接决定客户端能否识别该合集。

### 11.1 现象

合集「实用工具🔧」（`ca23743b-cdce-42c5-b15c-29d28a25c80c`，作者 `e046627d-…`）
已被当前账号收藏（`is_favourited=true`），其内的动态也确实被收藏、并出现在
`GET api/v2/favourites` 的第一页里，但客户端"收藏夹（合集）"就是解析不出它，
而其它合集都能解析。

### 11.2 实测矩阵（决定性证据）

`GET api/v2/favourites?last_id=&per_page=10` 翻完共 33 条（4 页），其中 10 条带
`post_collection_id`。逐条比对「这条动态里有没有内嵌 `post_collection` 对象」与
「该合集真实的 `visibility`（取自 `GET api/v3/post_collections/{id}`）」：

| 合集可见性 | 条数 | 动态里是否带内嵌 `post_collection` |
| --- | --- | --- |
| `public_visibility` | 8 | **8 / 8 有**（键存在，含 `id/name/description/visibility`） |
| `collection_visibility` | 2 | **0 / 2 有** —— **该键整键缺失**，只剩 `post_collection_id` |

两个 `collection_visibility` 用例：`ca23743b-…`「实用工具🔧」（`is_favourited=true`,
`posts_count=9`）、`6238a247-…`「🅰️🈂️💱」（`is_favourited=false`, `posts_count=339`）。

配套实测：

* **单条接口同样缺失**：`GET api/v2/posts/c7b15ed4-…` → 200，但
  `has_post_collection_key=false`，只给 `post_collection_id`。即从动态详情页也读不到内嵌对象。
* **合集本身读得到**：`GET api/v3/post_collections/ca23743b-…` → 200，返回完整
  `name="实用工具🔧"` / `visibility="collection_visibility"` / `is_favourited=true` / `posts_count=9`。
* **内容仍可读**：`GET api/v2/posts/profile?user_id=e046627d-…&post_collection_id=ca23743b-…`
  → 9 条（与 `posts_count` 一致）。

### 11.3 结论与客户端口径

1. **不得把"内嵌 `post_collection` 对象"当作识别合集的必要条件**；
   `post_collection_id` 才是可靠字段。
2. 收录时若内嵌对象缺失，用 `post_collection_id` + 动态作者兜底
   （动态作者即合集作者：实测 `post.user.id == collection.user_id`），
   名称/条数随后用 `GET api/v3/post_collections/{id}` 补。
3. **`visibility` 是影响字段结构的维度**：以后再遇到"某个字段时有时无"，
   先查它，不要先怀疑客户端解析。
