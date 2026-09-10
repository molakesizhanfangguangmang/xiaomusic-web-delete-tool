# xiaomusic-web-delete-tool

给 **hanxi/xiaomusic v0.6.1**（aarch64 / RK3568 小爱音箱盒子）的默认 web 控制面板，
以**纯静态增强**方式加一个「工具」区：主页叠加入口 → 工具一层页(landing, 读 tools.json 渲染卡片) →
各二级工具页。全程**不碰容器内任何 `.py`/设置/conf/压缩主干 js**，一律复用 xiaomusic 自带接口。

现内置两个真实工具：
- **删除歌曲**（`delete-song`）—— 从已下载 download/ 单选一首，二级确认后永久删除（复用 `POST /delmusic`）。
- **链接下载音频**（`bili-url-download`）—— 粘贴 B 站视频/分享链接（或其它可解析 URL），交给后端
  `POST /downloadonemusic`（容器内 yt-dlp 抽音轨转 mp3 落 download/），前端轮询 `GET /download_progress` 显示进度。

> 适用版本：`hanxi/xiaomusic:v0.6.1`。删除链路已按 US-001~US-005 五个故事完成并真机验证；
> 链接下载工具为纯静态实现(不动后端)，尚未在任何实机 apply——安装只拷静态树，见下。详情 `docs/`。

## 仓库布局

```
README.md                   ← 本文件（总览）
README_draft.md             ← 主设计稿（US-003/004：落点表、landing↔registry、注入器作用域、安装/回滚）
xiaomusic-tools-pkg/        ← 一键安装包（给别人直接用）
│  ├─ README.md             ← 安装 / 使用 / 回滚 / FAQ
│  ├─ install.sh            ← 幂等安装（可 --dry-run），default 容器 xiaomusic
│  ├─ uninstall.sh          ← 幂等卸载 / 回滚
│  └─ static/xiaomusic_tools/   ← 拷进容器 /app/xiaomusic/static/ 的整棵静态树
xiaomusic_tools/            ← 静态源（等价于 pkg/static 内那棵，作 diff 参照源；每工具一个子目录）
   ├─ delete-song/          ← 「删除歌曲」二级工具页
   └─ bili-url-download/    ← 「链接下载音频」二级工具页
docs/
   ├─ prd.json              ← 删除链路五 story 与该验记录（passes 全 true）
   ├─ doc_frontend.md       ← 前端壳 / 接入点 / 鉴权只读资料
   └─ doc_backend.md        ← 删除链路(/delmusic 与名单源)只读资料
```

## 快速上手（安装到目标 Docker 宿主/容器）

到 `xiaomusic-tools-pkg/` 目里执行：

```sh
cd xiaomusic-tools-pkg
./install.sh --dry-run     # 先只读预览会做什么
./install.sh               # 默认容器名 xiaomusic，可用 -c <name> 改
```

→ 打开控制面板即可见主页「工具」入口 → landing（工具卡片）→「删除歌曲」/「链接下载音频」。

移除（回滚）：

```sh
./uninstall.sh     # 删主页那行 + 移除 /app/xiaomusic/static/xiaomusic_tools 整树
```

详细说明 / 边界 / FAQ 见 `xiaomusic-tools-pkg/README.md` 与 `README_draft.md`。

## 边界与保证

- 纯静态新增：不动 `.py` / 设置 / conf / 压缩主干 js；只拷静态树 + 主页尾幂等插一行。
- 删除仅单选且须二级弹窗确认，无「一键清空/批量」。
- 删除真实对象 = `/app/music/download/*.mp3`（由既有 `POST /delmusic` 处理），
  删后经 `/refreshmusictag` 清 tag 残留；tmp/ 与音箱设备端缓存不在范围内（设备端不可达）。
- **链接下载工具**只调既有 `POST /downloadonemusic` + `GET /download_progress`（file.py 自带、带会话鉴权），
  不改任何后端代码；B 站抓取强依赖容器内 `yt-dlp` + 配置里的 `cookie`/`代理`（`--cookies`/`--proxy` 由 config 注入，
  见上游 network_utils），遇 HTTP 412/需登录属运行环境问题（非本页逻辑，可用「上传 yt-dlp cookie」端点改善）。
- 鉴权复用同源会话 cookie，不绕过、不自造。
- 包内不含任何 cookie / 登录态 / 音乐 / tag_cache 数据或真实文件。
