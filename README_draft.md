# README（草案）— xiaomusic 主页「工具」入口 + 工具注册表 + 「删除歌曲」二级工具

> 本文是本 mission README 的一节草稿（涵盖 US-003 静态产物与 US-004 主页入口叠加：
> US-003 = 工具注册表 + 删除歌曲二级页底座；US-004 = 让 default 主页能点到这些工具）。
> 仅说明这批**纯静态新增文件**的用途、文件间相对路径约定，以及将来放容器 static 下的确切落点
> （**只写文档，绝不 docker cp**，docker 动作归 US-005 install/apply，不在此 worker 范围）。

## 0. 定位一句话

给 hanxi/xiaomusic v0.6.1 的默认皮肤控制面板新增一整套**静态新增、可回滚**的「工具」链路：
```
default 主控制面板（工具入口） → 工具一层页 index.html（读注册表渲染卡片）
                                 → 任一二级工具（如「删除歌曲」/delete-song/index.html → POST /delmusic）
```
底座 US-003 提供「工具注册表 + 一个删除已下载歌曲纯静态二级页」；US-004 提供「主页『工具』
按钮 → 一层页」这段接线。全部是**只写 static 的新加文件**：不触碰任何 `/app/xiaomusic/**/*.py`
内核代码、不改写控制器、不改压缩主干 js；二级页删歌全走既有 `POST /delmusic`。

适用界面 / 服务：
- 目标皮肤：默认主题 `default`。端口/宿主服务无侵入。
- 鉴权：`/static/**` 与后端 `/musiclist`、`/delmusic` 均由同一
  `AuthStaticFiles` + `session cookie / HTTP Basic` 保护（`doc_frontend §3`），页面同源直调即可。

## 1. 目录树与各自作用

产物镜像目录会整体对应容器 **static 子目录的根**。当前静态产物（US-003 + US-004）内容：

```
deliverables/
├── README.md                  ← 本文件
└── xiaomusic_tools/           ← "工具区" 静态根（与 default 皮肤同级的独立目录）
    ├── index.html             ← US-004 工具一层页(landing)骨架（加载 tools.css/tools.js）
    │                            → docker: static/xiaomusic_tools/index.html
    │                            （web 可达 /static/xiaomusic_tools/ 与 /static/xiaomusic_tools/index.html）
    ├── tools.css              ← 一层页样式（自包含；色板同 delete-song/tool.css）
    ├── tools.js               ← 一层页逻辑（读 ./tools.json 渲染卡片，click 跳 item.url）
    ├── tools.json             ← 工具注册表（扩展位）→ docker: static/xiaomusic_tools/tools.json
    │
    ├── entry/
    │   └── tools-entry.js     ← US-004 主页入口注入器（唯一的<src>注入层，见 §「主页入口」）
    │                            → docker: static/xiaomusic_tools/entry/tools-entry.js
    │
    └── delete-song/           ← "删除歌曲" 工具的子目录（US-003 底座，未动）
        ├── index.html         ← 二级页骨架（加载 tool.css/tool.js）
        ├── tool.css           ← 页面样式（自包含，不污染 default/main.css）
        └── tool.js            ← 全部逻辑（vanilla，无 CDN，可离线）
```

### tools.json —— 工具注册表（registry）
- 约定结构（顶层常量，供未来工具/主页遍历）：
  ```jsonc
  {
    "version": 1,
    "items": [
      { "id": "delete-song", "title": "删除歌曲", "icon": "♻",
        "url": "/static/xiaomusic_tools/delete-song/index.html",
        "desc": "从已下载歌曲中单选一首，二级确认后永久删除", "disabled": false }
    ]
  }
  ```
- item 字段：`id/title/icon/url/desc/disabled?`，此处**只实现 "删除歌曲" 一项**；数组顶部注释即
  **扩展位说明**——将来新增工具只需 append 一项并把对应的 `xiaomusic_tools/<id>/index.html`
  根绝对 url 填进 `url`，无需改任何 python。
- `url` 用**根绝对路径** `/static/...`：本前端无 `<base>`、页面靠真实 http 路径定位
  （`doc_frontend §3.3`），与 md.js / downloadtool.html 的 goto 习惯一致；任何加载本注册表的
  页面（如后续主页注入代码）用得稳定。

### delete-song/…… —— 删除工具二级页
- `index.html`：加载 `./tool.css`、`./tool.js`（同目录相对，自包含）。
- `tool.js` 逻辑（对应 `doc_backend §5(a)` 成熟两步方案，**零后端改动**）：
  1. 页面 load → `GET /musiclist`；取返回对象中 **download/ 区那个键**（内核将 download/ 组
     rename 为「下载」，故默认 `data["下载"]`，兜底 `data["download"]`）当作“已下载歌曲名单”，
     每个值为名字键数组（文件名去扩展名），单选渲染为可点击单选框列表。
  2. 仅当**单选一首**后，页面底部「删除」按钮才可用；无"全选/一键清空/批量删除"任何入口。
  3. 点「删除」→ 弹**二级确认弹窗**：显示将删文件名 + “<strong>不可撤销·永久删除</strong>”
     强提示 + 「确认删除 / 取消」两按钮；必须再点「确认删除」才会发删除。
  4. 确认后 `POST /delmusic`，body `{"name":"<名字键>"}`，`Content-Type: application/json`
     （wire 与 downloadtool.html 的 $.ajax 一致；本页用 fetch + same-origin 复用会话 cookie）。
     注意**后端对“名字不存在/删失败”也一律回 "success"** → 成功判定以**删除后重取
     `/musiclist` 确认该键消失**为准（del_music 内部同步 rescan，POST 返回后列表已收敛，
     `doc_backend §1e/§3`）。
  5. 确认删除成功（该键已从「下载」名单消失）后，页面再补一发 **POST /refreshmusictag**
     洗掉 `cache/tag_cache.json` 里该歌残留旧标签（`doc_backend §4`：delmusic 只 os.remove
     download/*.mp3，不自动清 tag_cache；`/refreshmusictag`(music.py:322) 才把 tag_cache 重建到
     现盘集合。不用 `/api/music/refreshlist`(L341)——它只 gen_music_list 不碰 tag_cache）。
     refreshmusictag 为 fire-and-forget：失败仅换提示（tag 条目可能短暂残留），不改变删除判据。
     成功后/失败均有顶部状态条与结果反馈；删除后名单已自动刷新。
- 异常处理与提示：加载失败（网络）、空列表、以及 **401/403 会话失效/未过鉴权** 分支：
  页面提示并提供「触发一次 Basic 登录后返回」按钮（顶层导航到受保护 static 页以唤起浏览器
  Basic 弹窗，`doc_frontend §3.2`）。
- 单曲无法区分“同 basename 只删到它解析到的那个物理文件”的历史语义——工具页因此只按
  `/musiclist` 提供的名字键展示与回传，不做“两个同名清两个”的承诺（`doc_backend §2/§5`）。

### 相对路径约定（与注册表 url 相互印证）
- 注册表与二级页都用**根绝对路径 `/static/<工具根>/<目录>/…`**，跨目录、跨皮肤稳定。
- 页面内部资源引用用**页面所在相对路径** `./tool.css` / `./tool.js`，天然随目录搬移可带。
- 主页「工具」入口(US-004)goto 的是**固定根绝对地址 `/static/xiaomusic_tools/index.html`**(landing)；xiaomusic 的 StaticFiles 不自动列目录/不回退 index，裸目录 `/static/xiaomusic_tools/` 实测 404，故指向显式文件 index.html。
  而不是某个具体工具；由 landing 读注册表后 `location.href = item.url` 才落到真实二级页。
  这样新增工具的跳转全由注册表 items 驱动，主页注入器与 landing 都不用因加工具而改。

## 2. 容器 static 落点（docker 侧；只文档，不执行）

复制 `deliverables/xiaomusic_tools/` 整个目录到绑定的 static 目录，最终在 web 上等价于：

| 仓库内文件 | 容器内绝对路径 | 浏览器可达 URL |
|---|---|---|
| `xiaomusic_tools/tools.json` | `/app/xiaomusic/static/xiaomusic_tools/tools.json` | `/static/xiaomusic_tools/tools.json` |
| `xiaomusic_tools/delete-song/index.html` | `/app/xiaomusic/static/xiaomusic_tools/delete-song/index.html` | `/static/xiaomusic_tools/delete-song/index.html` |
| `xiaomusic_tools/delete-song/tool.js` | `/app/xiaomusic/static/xiaomusic_tools/delete-song/tool.js` | `/static/xiaomusic_tools/delete-song/tool.js` |
| `xiaomusic_tools/delete-song/tool.css` | `/app/xiaomusic/static/xiaomusic_tools/delete-song/tool.css` | `/static/xiaomusic_tools/delete-song/tool.css` |
| `xiaomusic_tools/bili-url-download/index.html` | `/app/xiaomusic/static/xiaomusic_tools/bili-url-download/index.html` | `/static/xiaomusic_tools/bili-url-download/index.html` |
| `xiaomusic_tools/bili-url-download/tool.js` | `/app/xiaomusic/static/xiaomusic_tools/bili-url-download/tool.js` | `/static/xiaomusic_tools/bili-url-download/tool.js` |
| `xiaomusic_tools/bili-url-download/tool.css` | `/app/xiaomusic/static/xiaomusic_tools/bili-url-download/tool.css` | `/static/xiaomusic_tools/bili-url-download/tool.css` |
| `xiaomusic_tools/index.html`（US-004 landing） | `/app/xiaomusic/static/xiaomusic_tools/index.html` | `/static/xiaomusic_tools/index.html`（注意：目录本身 `/static/xiaomusic_tools/` 因 StaticFiles 无目录索引会在实机 404，必须用显式 index.html） |
| `xiaomusic_tools/tools.css` | `/app/xiaomusic/static/xiaomusic_tools/tools.css` | `/static/xiaomusic_tools/tools.css` |
| `xiaomusic_tools/tools.js` | `/app/xiaomusic/static/xiaomusic_tools/tools.js` | `/static/xiaomusic_tools/tools.js` |
| `xiaomusic_tools/entry/tools-entry.js` | `/app/xiaomusic/static/xiaomusic_tools/entry/tools-entry.js` | `/static/xiaomusic_tools/entry/tools-entry.js` |

static 挂载与鉴权出处：`api/app.py L83 app.mount("/static", AuthStaticFiles(directory=<static>))`。
手动核对/回滚：删除下面对应文件即可（纯新增，无覆盖、不含 python）。

将来到位的 **docker cp**（US-005 才执行，此处仅为给 install 脚本的手稿）：
```bash
docker cp deliverables/xiaomusic_tools  xiaomusic:/app/xiaomusic/static/
```
（宿主机执行，需先把本目录拷到宿主机侧；`docker restart xiaomusic` 无需——static 是即时读盘，
纯文件新增不重启即可见。US-005 会给可回滚/幂等封装。）

## 3. 适用范围与限制（产品面提示，来自 doc_backend）

- 删除范围：仅 **download/ 区下载的单个真实 mp3/flac…**（持久卷），删后**不同步清理**
  `picture_cache/`、`tmp/` 哈希中间态、以及音箱端已缓存 URL。`cache/tag_cache.json` 残留旧标签
  条目由本页删除成功后的 **POST /refreshmusictag** 补洗（选它而非 /api/music/refreshlist 依
  `doc_backend §4`：只有前者才重建到现盘 tag 集合）；若该补洗失败，仅提示，歌曲标签里可能短暂
  残留该歌条目。无法清洗者仍保持现状说明。
- 本工具不会也不能做到：批量、下载区之外的缓存/tmp 清理、改名前的多同名消歧（撞名只删内核
  解析到的那份文件）。希望保留这些边界文案供 UI/后续 story 取舍。

---

## 4. US-004 · site 导航闭链（主页 → 工具一层页 → 二级页 → 调既有接口）

目标可见闭环（验收 6）：

```
default 主控制面板(/static/default/index.html，按钮行 .mode-controls)
   └─ 点「工具」(由 tools-entry.js 注入的 icon-item)
        └─ 工具一层页 landing  /static/xiaomusic_tools/        (index.html)
             └─ 读 ./tools.json → 渲染每张工具卡片(registry items)
                  └─ 点某卡 → 跳 item.url（如 /static/xiaomusic_tools/delete-song/index.html）
                       └─ 执行删除 → POST /delmusic（既有接口）
```

接线三要素：
1. **主页「工具」入口** —— 由注入器 `entry/tools-entry.js` 在页面运行时把它追加进
   `.mode-controls`（镜像 在线搜索/设置 等既有 `icon-item` 结构），click 后 `goto` 固定
   landing 的根绝对地址(跳转用) `/static/xiaomusic_tools/index.html`（容器侧该目录仍可存在多文件/JS 相对加载）。
2. **工具一层页 landing=** `xiaomusic_tools/index.html`（+ `tools.css`/`tools.js`），同目录
   `fetch('./tools.json')` 把每个 `item` 渲染成可点卡片；`disabled:true` 的项置灰不跳。
   对未来往 registry append 的工具有**自动扩展**效果：加一项即多一张卡。
3. **二级页=** 各 `xiaomusic_tools/<id>/index.html`（目前即 US-003 的 delete-song 二级页），
   registry 里 `item.url` 均已为根绝对 `/static/...` 串，与登录/反代无歧义地可达。

> 为什么主页那一下要“落地到 landing 而非直接 item.url”：US-003 就把 architecture 定成
> 「主页只放一个『工具』总入口」，registry 是唯一“还有什么工具”的真相源 —— landing 让新工具
> 完全不用回主页加按钮（验收 2“更多工具可展开”成立）。
> landing 与 registry 放同目录，读 `./tools.json` 是纯相对、同 AuthStaticFiles、零 base/反代坑。

### 4.1 扩展位衔接（US-003 → US-004）
- 想再增一个二级工具（例如“填链接离线下载”“清理缓存”占位）：
  1. 新建 `xiaomusic_tools/<tool-id>/index.html`（+ 各自 tool.css/tool.js）；
  2. 在 `tools.json` 的 `items` **append 一项**：
     ```jsonc
     { "id": "...", "title": "…", "icon": "…",
       "url": "/static/xiaomusic_tools/<tool-id>/index.html", "desc": "…" }
     ```
  这样主页入口、landing、二级页三者**都不需要再改任何代码**——主页「工具」入口已指向
  landing，landing 会遍历 registry 自动多出新卡。即 US-003 留的“纯数据 append 扩展位”
  在此真正被 landing 消费。

### 4.2 注入器最小作用域（自查/验收 5 依据）
`entry/tools-entry.js` 以一个立即执行函数包起，**不定义任何全局**；逻辑只做三件事且都在自己
新建的那个节点上：
- `document.querySelector('.mode-controls.button-group')` 一次定位挂载点（找不到即返回，不影响主页）；
- 查 `[data-xtools-entry="1"]` 防重复注入；
- `host.appendChild(新 icon-item)`，且只在该节点挂一个 `addEventListener('click',→landing)`。
它**不**给容器/父节点加任何委托监听、不碰 md.js 任何函数与 `.component-overlay`/closeAllDialogs
等管理区、无 `onclick=` 全局属性绑定（全部作用域在 IIFE 内）。正文每按一次 Enter/空格走 md.js 既有
`[role=button]` 键盘支持触发的 click，与其余图标入口行为一致，不是本注入器的额外处理。
`.icon-item` 中 `<p>` 文本用 **“工具”**；md.js 禁用名单只含 搜索/定时/测试（web_device 模式），
“工具”不在内，故两种设备模式都不会误禁本入口。

### 4.3 鉴权往来（全部同 `<port>` 端口、无新登录维度）
主页、landing(读 ./tools.json)、二级页、以及它们调的后端(如 /musiclist、/delmusic) 同在
AuthStaticFiles → AuthStaticFiles + session cookie / HTTP Basic 保护下。跳转或 fetch 首次未过
鉴权时，由**浏览器标准 Basic**处理(与服务本身其它页一致)；landing 还在 401/403 分支给出
「重新登录后返回」按钮。注入器本身不做任何登录操作，它只是 static 页面之一。

---

## 5. US-004 · 主页入口“新增形态”安装与回滚（仅文档）

> 落到 default 皮肤只需要两步：① 把 `xiaomusic_tools` 整棵静态树拷到容器 static 下；
> ② 在 default 主页 `default/index.html` 的**末尾（`</body>` 前的最后一个 `</script>` 之后）**
> 追加**唯一一行** `<script>` 引用注入器。其它任何位置/文件都不用改——344 行主页正文原样保留，
> 压缩主干 js、`.py` 一律不动。

### 5.1 安装
1. **拷静态子树**（US-005 执行；docker 侧）：
   ```bash
   docker cp deliverables/xiaomusic_tools  xiaomusic:/app/xiaomusic/static/
   ```
   → 于是 web 上出现 `/static/xiaomusic_tools/{index.html, tools.css, tools.js, tools.json,
   entry/tools-entry.js, delete-song/*}`（§2 表）。无需 `docker restart`（static 即时读盘）。
2. **主页加一行**（宿主机只有容器内的 default/index.html 被 baked，需对那份追加；文档写法
   示意，末尾 `</body>` 前）：
   ```html
   <!-- US-004 工具入口注入器 -->
   <script src="/static/xiaomusic_tools/entry/tools-entry.js"></script>
   ```
   保存后刷新主页即可见「工具」图标（在“在线搜索”之后、设备按钮行内）。如需避免旧缓存可用
   与 md.js 同款 `?version=<时间戳>` 查询串，但静态即时读盘一般不必。

### 5.2 回滚
- 最小回滚（仅撤主页入口，保住目录/工具）：
  把 5.1 追加的那 **一行** `<script>…tools-entry.js…</script>` 从 default/index.html 删除 + 保存。
  → 主页立即回到原状态（无“工具”入口）。landing 等目录文件仍可直达但无人从主页点进。
- 彻底移除整条功能链（连同 US-003 工具页）：
  ```
  # 容器内删除整棵 static/xiaomusic_tools
  docker exec xiaomusic rm -rf /app/xiaomusic/static/xiaomusic_tools
  # 再顺手把主页那一行 script 注释/移掉（恢复纯原版 344 行主页）
  ```
  因全部为**新增文件 + 一个可逆行**，无覆盖既有文件，恢复等同删目录/删行，零破坏。
  （US-005 会给可回滚/幂等封装；本节是给读者与那只脚本的“落点 + 逆操作”事实清单。）

### 5.3 自查（静态，Run-disabled）
- tools.js / tools-entry.js：`node --check` 无语法错。
- tools.json：`python3 -m json.tool` 合法（仍为纯数据，未因本次加 landing/入口而改语义）。
- index.html(landing)、tools.js 引用的 getElementById 目标（`#tt-status/#tt-grid/#tt-count`）均
  存在于 index.html DOM；注入器引用的挂载点 `.mode-controls.button-group` 在 research 副本
  default_index.html 内实际存在。
- 页面无任何 CDN/http 外链；内部资源一律相对 `./`(同目录) 或根绝对 `/static/…`。
