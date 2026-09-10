# xiaomusic 工具区 —— 一键安装包（xiaomusic-tools）

> 打包产物对应 story **US-005**：把前序纯静态产品（**US-003** 删除下载歌曲工具 + **US-004**
> default 主页「工具」入口 / landing + tools.json 注册表）封装成可在宿主机一键复现的
> bash 安装包 install.sh / uninstall.sh + 本 README。
>
> 引擎版本 / 适用对象：**hanxi/xiaomusic v0.6.1**（Arch aarch64 / RK3568 小爱上运行时）。
> 前置：一台能跑 `docker`（等价的 Linux 宿主机），目标容器默认名 `xiaomusic`

本包是对 xiaomusic 默认皮肤控制面板的**纯静态、可回滚增强**。它
**绝不碰容器内任何 `.py`、设置、conf、压缩主干 js 或除 default 之外任何东西**——
它做的事只有三件：拷静态文件、给 default 主页尾部幂等插一行、重启容器。以及卸载时
原样撤销这三件。

背景与设计依据见上层层产物 `../README_draft.md`（US-003/004 的落点表、landing↔secondary
导航链、注入器最小作用域、registry 结构说明）。本页只讲"别人怎么用"。

---

## 0. 这份包里有什么

```
xiaomusic-tools-pkg/
├── install.sh                          ← 安装（幂等，可 --dry-run 先预览）
├── uninstall.sh                        ← 卸载 / 回滚（幂等）
├── README.md                           ← 本文件（安装 / 使用 / 回滚 / FAQ）
└── static/
    └── xiaomusic_tools/                ← 要拷进容器 /app/xiaomusic/static 的整棵静态树
        ├── index.html                  ← 工具一层页(landing)：读 tools.json 渲染卡片
        ├── tools.css  /  tools.js      ← landing 样式与逻辑（无 CDN / 可离线）
        ├── tools.json                  ← 工具注册表（纯数据；expand 位）
        ├── entry/tools-entry.js        ← 主页「工具」入口注入器（唯一被 <script> 引的那个）
        └── delete-song/
            ├── index.html              ← 「删除歌曲」二级工具页
            ├── tool.css
            └── tool.js                 ← 逻辑：/musiclist 单选 → 二次确认 → /delmusic
```

`install.sh` 与 `uninstall.sh` **只能复制/删除 `static/` 下这一棵** + 对 default 主页
`index.html` 尾部改一行/删一行，其余一概不碰。就算你要换 / 扩充工具，也只往
`static/xiaomusic_tools/tools.json` 的 `items` append + 放新二级页目录，脚本原样运行。

---

## 1. 前置

- 一台具备 Docker 的宿主机（Debian / …）。`docker ps` 能列出运行容器。
- 目标容器 **hanxi/xiaomusic v0.6.1** 正在运行，默认名 `xiaomusic`。
- 容器内 static 根位于 `/app/xiaomusic/static`（本包即按此布局对应 `/static/…` 的 URL）。
- **若容器名不叫 xiaomusic**：两种给法，效果相同——
  ```bash
  ./install.sh   --container  你的容器名
  # 或
  CONTAINER=你的容器名 ./install.sh
  ```

> 老版本是否支持：本工具只需 default 皮肤主页仍为 `html + 一个可读 index.html`、且 static
> 目录仍由 AuthStaticFiles 挂载（v0.5+ 同一套结构）。本包版本声明锚在 v0.6.1；在更旧版本
> 或魔改镜像上请先 `--dry-run` 并人工核对落点表（`../README_draft.md §2`）。

---

## 2. 三步使用

把整个 `xiaomusic-tools-pkg` 拷到宿主机任意可执行目录后，`cd` 进去：

```bash
# ① 先看：仅打印将执行的命令，不写不改不重启（会做只读预检）
./install.sh --dry-run

# ② 确认无误后真正安装
./install.sh

#    （若目标容器名不是 xiaomusic：./install.sh -c 你的容器名）

# ③ 应用后即时可见
#    - 主页：http://<host>:<port>/static/default/index.html
#    - 工具一层页：http://<host>:<port>/static/xiaomusic_tools/index.html
```

安装脚本做的事（与 §3 一致），顺序：
1. 判容器运行中（不在则友好报错并退出非 0，不产生副作用）；尽力预检 static 落点权限；
2. `docker cp static/xiaomusic_tools  容器:/app/xiaomusic/static/`
   （即生容器内 `/app/xiaomusic/static/xiaomusic_tools/…`，web `/static/xiaomusic_tools/…`）；
3. 把 default 主页 `/app/xiaomusic/static/default/index.html` 拉到宿主机临时副本，**只在其
   末尾幂等追加一行**带唯一标记的注入脚本行（下面 §3），再 `docker cp` 写回；
4. `docker restart 容器`，让 bake 进镜像的那份 default 主页重新读盘。

### 应用后看到的闭环
```
default 主控制面板
   └─ 点「工具」图标  (由 tools-entry.js 注入，在设备按钮行 .mode-controls 内)
        └─ 工具一层页 /static/xiaomusic_tools/    (自动读 tools.json 渲染卡片)
             └─ 点「删除歌曲」卡片
                  └─ 删除歌曲二级页 /static/xiaomusic_tools/delete-song/index.html
                       ├─ /musiclist 单选一首已下载歌曲
                       ├─ 二级确认 → POST /delmusic {name}（永久删除 download/ 下真实文件）
                       └─ 成功判据 = 删后重取 /musiclist 该键消失 + /refreshmusictag 洗标签缓存
```

---

## 3. 幂等的「主页插一行」到底插了什么（请理解回滚为何安全）

安装只会往 default 主页 `index.html` 的**最末尾 append 一行**：

```html
<!--xtools_entry--><script src="/static/xiaomusic_tools/entry/tools-entry.js"></script>
```

要点：

- 这一行**行内自带唯一标记 `xtools_entry`**（放在注释里，不影响 HTML 解析），它是本包
  的专属名片。
- **已存在该标记 ⇒ 跳过**，重复运行 install 绝不重复插行。
- **已存在 tools-entry.js 但不带标记**（例如有人按旧版文档/手工加过同一行）⇒ 脚本**停住**
  要求人工审，不覆盖他人改动；确认无冲突后才可用 `--force` 再 append 自己的标记行。
- 主页若不像 HTML（找不到 `<html`）⇒ 同样停住，需要 `--force`。
- **删除（uninstall.sh）只删除含 `xtools_entry` 的那一整行**，其余正文逐字节原样写回。
  因此回滚到"安装前"= 只清了这一行注入，不误删任何用户内容（即使这行之后又有人
  append 了别的东西，我们的删除也以行为单位、只摘走自己的行）。
- 首页正文区、md.js、任何 .py 一律不改；`--force` 只是越过"主页已有他人引用"与"主页不像 HTML"这两道插行护栏（例如确认该"主页"实为测试文件），
  并不会扩大删除/覆盖范围。

> 万一 default 主页已被你大幅魔改到与 v0.6.1「原版 344 行」/预期形状差得太多（例如整体换皮，
> 连 `<html>` 都不在了），本脚本已设护栏停住。此时不建议强上 —— 可用**手动替代接线**：
> 不做主页插行，只保留 `/static/xiaomusic_tools/` 整树（工具一层页与各二级页独立可达），
> 需要时在你的主页里放一个自定义入口跳 `/static/xiaomusic_tools/index.html` 即可（详见
> `README_draft.md §5`）。

---

## 4. 卸载 / 回滚

```bash
./uninstall.sh --dry-run   # 先看将做什么
./uninstall.sh             # 真正回滚：
                           #  ① 移除 default 主页里的 xtools_entry 那一整行（原样恢复正文）
                           #  ② docker exec rm -rf 容器内 /app/xiaomusic/static/xiaomusic_tools
                           #  ③ docker restart 容器
```

幂等：目录已不在且首页已无标记 ⇒ 打印 "nothing to remove"，正常退出 0，不报错不重复动。

最小回滚（只想撤主页入口、保留工具页目录 / 想把 landing 继续当书签直连）：手工把 default
主页那**一行** `<!--xtools_entry-->…<script…tools-entry.js…</script>` 删掉即可，立即失效；文件
不受其它影响。彻底回滚请直接用 `uninstall.sh`。

> 若首页存在**不带标记**（手工/旧版）的 tools-entry 引用：uninstall.sh **不会**替你删它
> （避免动他人内容），它会照删本包目录并提示你按需手工清那一行以免残留 404。

---

## 5. 先试后装 / 失败了怎么办

- 先跑 `./install.sh --dry-run`：会做**只读**的容器检测与权限预检（不写容器、不发请求、
  不 restart），然后只打印"将执行"的 docker 命令。
- 失败自查两步：
  1. 我删/改的只可能是 static 下纯新增 + 首页那标记一行；
  2. 真出问题就 `./uninstall.sh`（或手工删那一行）即可恢复；两者都不碰内核 `.py` 与你的
     音乐文件（删除工具只在你**主动二次确认**时才对 download/ 内一首歌发删除）。
- Docker/容器类的报错请先 `docker ps` 核对容器名（默认 `xiaomusic` 可能不叫这个）。

---

## 6. 升级 / 重建容器后再应用

- **小版本体验新静态文件**（只改了包内文件、没动容器 default 主页那一行）：直接重跑
  `./install.sh`。整树是覆盖式 docker cp（同名文件被新版本叠回），主页那行已带标记 → 幂等跳过
  插行，最后 restart 一次即让新 static 生效。
- **删掉了 xiaomusic-tools 也撞不上冲突**：首页若已被你顺手删成没有标记，install 会照常
  重新把它加回来（因为没标记、也没别的引用）。
- **重建了容器**（重 pull 同镜像/把卷重建、容器名变回清新 default 主页原版）：
  直接 `./install.sh` 即可 —— 首页回到原版 344 行、无任何标记 → 脚本照常 tree-cp + 插一行
  + restart。卸载方向同理，重建后 `./uninstall.sh` 也安全（无标记时首页行移除就是 no-op）。
  → 所以本包**不怕容器重建**：状态取决于「首页有没有标记行 + 目录在不在」，跟镜像无关。

---

## 7. 常见问题（FAQ）

**Q1 为什么不"动内核"，你确定不会把我的服务器/歌弄坏？**
整个改动 = 只拷几个静态文件 + 在 default 主页尾部插一行/删一行 + restart 容器。没有改写任何
`.py`、没有覆盖 home 正文、没有改设置/conf、不碰其它皮肤。删除动作只由二级页在你**二次确认后**
对 download/ 单首下发 `POST /delmusic`（复用 v0.6.1 既有内核接口），失败也有判据兜底。卸载能把
这三件事原样撤销。风险面被锁在最小新增上。

**Q2 为什么是"纯静态新增"边界，好处在哪？**
新增文件都放 AuthStaticFiles 的 `/static` 挂载点下，同源同会话 cookie 即鉴权，几乎不需要重启
即可上线、回滚只删文件；同时因为都只是新增，与内核升级/镜像重建天然无耦合。代价是它只能做
内核既已有接口能表达的事（本包就只表达 `/delmusic`），不会发明"批量删除"之类内核没有的语义。

**Q3 为什么删除是真删、删的是 download/ 里的 .mp3/flac…？**
`/delmusic` 后端 `XiaoMusic.del_music` 走 `os.remove` 删 music_library 解析出的、download/
区持久卷里的真实音乐文件**本身**，所以是"永久删除、不可撤销"。工具页因此强制**单选 + 二次确认**，
并在提示里写明"不可撤销"。“下载/缓存”在 v0.6.1 界面上即 download/ 卷区（"下载"库分组）；本工具
管的就是那批真文件，而不是仅删个歌名 / 网页书签。

**Q4 删完为什么还要 /refreshmusictag（不删不行吗）？**
v0.6.1 里 `/delmusic` 只 `os.remove` 音乐文件，**不会**自动清理 `cache/tag_cache.json`（标签缓存）
里的旧条目——它保留的是上次扫描的标签，删文件后会带出一条"幽灵"旧标签。而两个"刷新"端点语义
不同：
- `POST /api/music/refreshlist`（music.py L341）：只重新 `gen_music_list` 扫盘，**不碰** tag_cache；
- `POST /refreshmusictag`（music.py L322）：把 tag_cache dump `{}` 后**按当前磁盘重建** → 能洗掉
  已删歌的残留旧标签。

所以删除工具在确认"名字键已从名单消失"之后，再多发一次 `/refreshmusictag`（fire-and-forget，
失败只降级为提示"标签可能短暂残留"，不改成功判据）。这是清幽灵标签的正确端点。

**Q5 单页鉴权（401/403 / 会话过期）怎么办？**
主页、landing、二级页、以及它们调的 `/musiclist`、`/delmusic` 全在同一个
`AuthStaticFiles` + session cookie / HTTP Basic 保护下（`<port>`/端口同源）。首次未过鉴权时由浏览器
标准 Basic 处理；landing 与删除页还在 401/403 分支给出「跳转一次 Basic 登录后返回」按钮，不会
静默重试删除。注：你拿到的分发页如果被前置了反代/改了端口，请让 `/static` 前缀照旧，页面本身
零跨域请求。

**Q6 我只想加个入口 / 少一个工具怎么办？**
加工具：往 `static/xiaomusic_tools/tools.json` 的 `items` append、并把新页放到
`xiaomusic_tools/<id>/`，重跑 `./install.sh`，landing 自动多一张卡（home 与 landing 都不用改代码）。
移除工具：卸下那一条的 `items` 与对应目录，重跑即可。删掉整个「工具」概念 = `./uninstall.sh`。

---

## 8. 与上层文档的关系 / 延伸阅读
- `../README_draft.md` — US-003/004 设计底稿：落点表（容器路径 ↔ web URL）、landing ↔ registry ↔
  二级页的数据流、注入器最小作用域、删除工具两步方案与 /refreshmusictag 理由、纯静态红线说明。
- `tools.json` / `entry/tools-entry.js` / `delete-song/*` 内的注释即各文件级文档。
- 脚本自身文件抬头注释 = 本 README 的技术摘要，两处一致。

---

## 版本记录
- **v0.1 (US-005)** 首个发布：install.sh / uninstall.sh / README + 来自 US-003/004 的整棵静态树。
  marker `xtools_entry`；默认容器 `xiaomusic`；支持 `--dry-run` / `--container` / `--force`。
