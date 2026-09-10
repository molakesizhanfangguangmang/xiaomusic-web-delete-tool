# US-001 前端壳与接入点资料（只读）— doc_frontend.md

> 目标：弄清 xiaomusic v0.6.1 web 前端（static 目录）结构、可在哪不加改动地叠「工具」入口、工具二级页应放哪个 static 相对路径、以及同端口调后端的方式。产出为证据型只读资料。
> 本文档所有结论均来自对运行中容器 `xiaomusic`（image `hanxi/xiaomusic:v0.6.1`，宿主机 `<user>@<host>`，web `<port>`）的**只读**命令。未对容器做任何写/删/重启/部署，无副作用 HTTP 调用。

---

## 0. 本次采用的关键只读命令（证据基座）

```bash
# 经 ssh 包装进入宿主机后执行容器内只读命令（绝对路径）：
host.sh "docker exec xiaomusic find /app/xiaomusic/static -maxdepth 2 | grep -v icons | head -80"
host.sh "docker exec xiaomusic sh -c 'ls -la /app/xiaomusic/static/default/; ls -la /app/xiaomusic/static/default/merge/'"
host.sh "docker exec xiaomusic cat -n /app/xiaomusic/api/app.py"
host.sh "docker exec xiaomusic sh -c 'cat -n /app/xiaomusic/api/routers/__init__.py'"
host.sh "docker exec xiaomusic sed -n '1,40p' /app/xiaomusic/api/routers/music.py"
host.sh "docker exec xiaomusic sh -c 'wc -l /app/xiaomusic/api/dependencies.py; grep -nE \"class AuthStaticFiles|async def __call__|verification|disable_httpauth|cookie_name\" /app/xiaomusic/api/dependencies.py'"
# 另 docker cp 副本进 loop 目录（readonly 研究，不改容器）：
#   docker cp xiaomusic:/app/xiaomusic/static/default/{index.html,md.js,downloadtool.html,...} → research/
```

---

## 1. 前端版本 / 皮肤确认

### 1.1 有多个独立皮肤，默认主题即用户访问的页面

`/app/xiaomusic/static/` 下同级的皮肤目录来自我列文件清单核对：

```
/app/xiaomusic/static/
  default/        # 默认主题（用户实际操作面板）
  tailwind/       # Tailwind 主题
  pure/           # Pure 主题
  xplayer/        # XMusicPlayer
  soundSpace/
  onlineSearch/   # 在线搜索工具
  iwebplayer/     # iPhone 播放器
  weapp/          # 小程序二维码
  index.html      # 主题选择门户（static 根）
  sw.js, manifest.json, favicon.ico…
```

- 根 `/static/index.html` 是**主题门户**，列出各主题链接（证据：文件 L60-101，链接形如 `<a href="/static/default/index.html">默认主题</a>`…`<a href="/static/onlineSearch/index.html">OnlineSearch</a>`）。
- 用户给的 URL `http://<host>:<port>/static/default/index.html` = 「默认主题」播放控制面板。
- 页面 title 证据：`default/index.html` L9 `<title>小爱音箱操控面板</title>`。

### 1.2 default 皮肤内文件角色（非「全部压缩」）

`/app/xiaomusic/static/default/` 清单（容器内 Ls，Jun 9 = 镜像构建日）：

```
drwxr-xr-x ... 默认主题目录
  index.html          17060 B   操控主页面（HTML 骨架，344 行，非压缩）
  md.js               54771 B   本皮肤主交互 JS（1967 行，肉眼可读，非压缩）
  main.css            22477 B   皮肤样式（downloadtool.html 也用）
  setting.html        38774 B   设置页
  setting.css, setting.js
  downloadtool.html    3725 B   「歌曲下载工具」独立静态页（B 站导航/单曲下载）
  m3u.html             2544 B   歌单m3u 页
  debug.html
  jquery-3.7.1.min.js  87533 B   皮肤自带 jQuery(3.7.1)
  merge/                        歌单导出子应用(Spa)
    index.html         323 B
    main.js          375516 B   压缩(单文件 SPA，标题=“歌单导出工具”)，与“控制面板”无关
```

> 重要更正：merge/main.js（375KB 压缩）**不是**默认皮肤的控制脚本；它属于 default 下 `merge/` 的独立「歌单导出工具」Spa（merge/index.html L3 标题=歌单导出工具，L5 `main.js type=module`）。**default 主控制面板真正用的交互 JS 是 `md.js`（可读、未压缩）与 index.html 尾部的内联 `<script>`。** 这大幅降低在默认皮肤上做前端叠加的难度与体积门槛。

- `default/index.html` 加载物证据：L16 `<script src="./jquery-3.7.1.min.js?version=...">`、L18 `main.css?version`、L末尾（index 内，正文 344 行内）`<script src="./md.js?version=...">`；md.js 未压缩明文（可直接读）。
- 默认皮肤跳转别的静态工具的既有先例：index.html L245-… 内联里 `function goOnlineSearch(){ window.location.href = "/static/onlineSearch/index.html"; }`（直根路径跳到另一 static 子目录页面）。说明“静态子目录页面 + 根路径 location 跳转”已是原生惯用法。

结论：用户操作皮肤 = `default`（title 小爱音箱操控面板），桌面与移动通用，脚本 md.js 可读，具备低风险叠加条件。

---

## 2. 主页结构可扩展位（在不改压缩主干 JS 的前提下）

### 2.1 主页 DOM 具象给出的天然“图标入口行”

`default/index.html` 底部 `.buttons > .mode-controls` 是一排图标入口，每个是 `<div class="icon-item">…<p>中文…</p></div>`，例如：

```
L133-155 (粗略) <div class="buttons"><div class="player-controls button-group">…播放控制…</div>
      <div class="mode-controls button-group">
        …收藏(favorite) 音量 搜索 定时 测试…
        <div onclick="openSettings()" class="icon-item" …>设置</div>
        <div onclick="goOnlineSearch()" class="icon-item device-enable" …>在线搜索</div>
      </div>
```

md.js 对 `.icon-item` 有统一逻辑：本机(web_device)模式下 `.icon-item` 文本是“搜索/定时/测试”的会 `.addClass("disabled")`（md.js 对应片段），其余默认可用——新增工具入口若复用一个不在那个禁止名列表里的 `<p>` 文本（如「工具」），本机模式下不会被禁用。

### 2.2 入口定位候选（按“侵入度”由低到高建议）

| 候选 | 改动面 | 风险 | 说明 |
|---|---|---|---|
| A. 新增 sibling 静态页 `default/tool.html`（+ 独立 css/js/registry 均只追加文件） | **纯新增文件，零改动** | 极低（如同 downloadtool.html 先例） | 可先做成 URL: `/static/default/tool.html` 可直达。但主页没有入口链接之前，需要手动/书签进入。 |
| B. 在 `default/index.html` 尾部追加一段内联 `<script>`，`$(…).after/append` 一个「工具」icon-item（jQuery 已全局在 skin 里） | 改动仅**此 344 行非压缩 html 的尾注一行块** | 低（追加而非改写；不在 md.js/main.js 内动） | 不需碰 375KB 压缩包；入口按钮在运行时由页面自身脚本注入。主页每次加载即出现「工具」。等价于现有页面尾部已有大量追加内联函数片段（rewind/forward/speed 那批），同款位置即可。 |
| C. 在 md.js 里补函数并在 html 写死 `<div … onclick="…">` | 改 md.js 一到两处 + html | 中（会覆盖时易丢、需版本同步） | 侵入 md.js 主交互文件，能不动尽量不动；但 md.js 可读可控，若 B 需要强耦合全局函数名也仅为追加函数。 |

推荐：默认走 **A 先建可直达的工具页，再以最小 B（html 尾部 inject + 非覆盖式）把主页入口接上**，能最大避免触碰任何已发布文件的核心逻辑；若不想在后续镜像重建后手工改 index.html，仅新增一个“注入用小 js”（把 B 那段脚本独立成工具页文件夹里的 injector.js，由 html 尾部一行 `<script src=…></script>` 引入者也可，见 §4 落点建议）。**可被 apply.sh 重放，且可能无需 python 改动。**

（决定权在实现阶段 US-003/004 worker；此处只给出证据与候选。）

### 2.3 风险提示的记录

- 皮肤内 html/js/css 都是**镜像 baked（Jun 9 mtime）**，改它们会在镜像重建后被还原 → 需要“补丁集 + apply 脚本”在重建后重放（这就是任务整体机制）。
- 覆盖某个既有文件（非纯新增）必须有版本对照与回滚（若把 index.html 打补丁，保留原文件差量）。
- 沿用可用性优先的纯新增模式可显著降低上述两类风险。

---

## 3. 相对路径与鉴权

### 3.1 静态文件挂载：AuthStaticFiles

证据（`/app/xiaomusic/api/dependencies.py`，281 行）：
- L211 `class AuthStaticFiles(StaticFiles):`；L217 `async def __call__(self, scope, receive, send)` — 在返回文件前做登录校验拦截。
- 挂载点（`/app/xiaomusic/api/app.py` L83）：
  `app.mount("/static", AuthStaticFiles(directory=f"{folder}/static"), name="static")` （folder = xiaomusic 包目录）
  ⇒ **凡 `/static/<相对路径>` 均由 AuthStaticFiles 提供，并在启用鉴权时先要登录。**

### 3.2 鉴权机制（conf/auth 相关）

- `dependencies.py`（证据片段）：
  - `verification(...)`（L108）：先读 `cookie_name = "xiaomusic_auth_session"`（L121）的 JWT；`session_secret=sha256(httpauth_password)`（L120）；否则走 HTTP Basic。
  - `config.disable_httpauth:` 为真时 L278-279 `app.dependency_overrides[verification]=no_verification`（即关鉴权）。
  - `AuthStaticFiles.__call__` 段 L225 `if not config.disable_httpauth:` 读取 `request.cookies.get(cookie_name)`，未过则回 401 + WWW-Authenticate Basic（L243-265）。
- API 路由都带鉴权依赖：`/app/xiaomusic/api/routers/music.py` L28（router 层，待 US-002/003 复核时以该行为准）`router = APIRouter(dependencies=[Depends(verification)])`；音乐相关接口全在此 router 内。plugin/router 亦等同理带依赖。
- conf 有实际鉴权凭据：容器内 `/app/conf/auth.json` 存在（只读目睹，具体值未读取/不外传）。默认皮肤访问需先过同一 Basic/会话 cookie。

### 3.3 相对路径 / base

- **没有 <base>、没有前端路由库**：页面靠真实 http 路径定位。md.js / downloadtool.html 一律用**根绝对象路径**调后端（例：md.js 中 `$.get("/musiclist")`、`$.ajax({url:"/delmusic"})` ；downloadtool.html 中 `url:"/downloadplaylist"`）。
- 既不要 `./xxx` 相对业务路由，也不要假设反代前缀重写的存在——根绝对象 `/xxx` 在同源（同 `<port>` 端口、已带会话 cookie）即可直达后端。工具页放 `/static/default/...`，调用 `/musiclist`、`/musicinfos`、`/delmusic` 即同源同鉴权，天然工作。

结论：新增页面放在 `/static/…` 下任意一处，**同一 AuthStaticFiles 及其会话 cookie** 一并适用，前端直接以根路径调用后端即可；无 base/路由前缀障碍。

---

## 4. 后端接口清单（前端删除工具实际要用的核心调用）

以下 loc 由 `music.py`（/app/xiaomusic/api/routers/music.py）实测，路由均带 verification。

| path | method | 关键入参 | 返回/说明 | loc(行) |
|---|---|---|---|---|
| `/musiclist` | GET | - | 播放列表树 dict: playlistName→array（含「收藏」）；md.js 据此渲染列表下拉 | L236-239 `async def musiclist`（get_music_list） |
| `/musicinfo` | GET | name, musictag | `{ret,name,url}`; url=播放地址 | L242-254 |
| `/musicinfos` | GET | name(list), musictag | `[{name,url,(tags)}…]` | L256-273 |
| `/musicinfos` | POST | body MusicInfosQuery{name:list, musictag} | 同上（防长 URL） | L275-289 |
| `/delmusic` | POST | body `MusicItem{.name}` | 调 `await xiaomusic.del_music(data.name)` 返回 "success" | L298-304 |
| `/refreshmusictag` | POST | - | refresh_music_tag() → {ret:OK} | L320-326 |
| `/api/music/refreshlist` | POST | - | gen_music_list() → {ret:OK}（刷新歌单/列表缓存） | L341-… |
| `/playingmusic` | GET | did | is_playing/cur…（前端播放器状态，非删除触发） | L216-234 |

- **删除单曲入口后端原样已具备**：md.js `confirmDelete()` 即 post `/delmusic`（`{name:音乐名}`）且默认皮肤已有删除单曲弹窗（`#delete-component` modal，L约 138-145）——说明“名字→删一首”是原生路径；我们工具页若要“删已下载/缓存歌”，最基本就是对 `/musiclist`（或针对性列表）列出的名字调 `/delmusic`，与内核无关。
- 是否还要额外后端（浏览 `download/` 目录原始文件而不仅是 /musiclist 网关）属 US-002 后端语义研究范畴，本文只在“前端能消费的接口”层面记录。

---

## 5. 结论段：「工具入口 → 二级页 → 调既有接口」是否可行

**可行，且是低风险路径。** 依据：
1. static 是 AuthStaticFiles 挂载的自由目录，往子目录放 `.html/.js/.css` 纯新增不加 python 即成可访问页（downloadtool.html 为该模式现成先例，URL `/static/default/downloadtool.html`）。
2. 同源网页原生用根路径 `/xxx` 调后端 & 沿用同一会话 cookie；无 base/路由前缀障碍。
3. 删除能力的后端底座（`/musiclist` + `/musicinfos` + `/delmusic` + `/api/music/refreshlist`）已经是根路径、带统一鉴权、前端消费现状，工具页只要枚举 `download` 名单并按名调用即可，不必新增 .py（除非 US-002 证明需要访问 raw 文件系统数据，属另行最小增补）。
4. 默认皮肤脚本 md.js 可读、入口图标行(.icon-item)结构清晰，主页加「工具」入口的风险可控（建议以最小 html 尾部内联/注入 js 挂载，不碰 375KB 压缩 SpA）。

**推荐静态落点（这套路径给后续 US-003 采纳）**
- 工具入口目标页：`/static/default/tool.html`（或独立工具目录 `/static/xiaomusic_tools/index.html` 更利于未来扩充多个工具，且与皮肤解耦；二选一时 prefer 独立目录:每工具一个子页，主页只放一个「工具」总入口更贴合“预留扩展位”设想）。
- 复用：`./jquery-3.7.1.min.js`、`./main.css`（与 downloadtool 相同取法）；新工具自带独立 css 避免污染皮肤。
- 主页入口：往 `default/index.html` 尾部追加一段注入（或 util js src），把含「工具」文本的 `.icon-item` 追加进 `.mode-controls`，click→`window.location.href="/static/<工具目录>/index.html"`。
- 配套要放的外围：工具注册 registry（tools.json/js）、README、apply.sh（容器重建后把上述新增文件以 `docker cp` 回到 static 对应目录并 `docker restart`）——都在静态文件层，不触碰 `.py`。

**遗留交给 US-002/后续确认的点**
- “已下载/缓存”名单应来自 `/musiclist`（用户前台可见文件）还是应扫描 `/app/music/download/*` 文件系统并核对 tag_cache → 决定是否需要一个极薄后端只读接口（若需要，US-005/后续在“不改内核语义”前提下最小增补）。本文结论是：纯前端可先落地，功能深度取决于 US-002 输出。

---

## Worker 自检（红线）
- [x] 未对容器做任何写/删/重启/部署，未调 POST/DELETE/PUT；
- [x] 所有容器访问均为只读命令（cat/find/ls/grep/sed/wc/cat/n）；docker cp 仅把文件副本带出到 loop 的 research/（不改容器文件）；
- [x] 只向 loop 工作区落盘（doc_frontend.md 与 research/ 副本）；未向 `<port>` web/容器/宿主机其它路径写文件；
- [x] 结论每条均带文件路径 + 行号/原片段 + 用过的只读命令出处。
