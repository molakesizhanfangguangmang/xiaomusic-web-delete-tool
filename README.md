# xiaomusic-web-delete-tool

给 hanxi/xiaomusic v0.6.1 的默认 web 控制面板加一个「工具」入口。

装法是往容器里拷一份静态文件，在主页尾部插一行脚本。工具区是一层页（读 tools.json 渲染卡片），
卡片点进去是各工具的二级页。全程不改后端代码，二级页调的都是 xiaomusic 自带的接口。

内置两个工具：

- 删除歌曲（`delete-song`）：从已下载 download/ 目录里单选一首，二级确认后删除。调用 `POST /delmusic`。
  删的是 download 目录下的真实音乐文件，不可撤销；只能单选，没有批量操作。
- 链接下载音频（`bili-url-download`）：粘贴 B 站视频/分享链接（或其它可解析 URL），交给后端
  `POST /downloadonemusic` 用容器内 yt-dlp 抽音轨转 mp3 落 download/，前端轮询 `GET /download_progress` 显示进度。

适用版本：`hanxi/xiaomusic:v0.6.1`。

## 仓库布局

```
README.md                   ← 本文件（总览）
README_draft.md             ← 设计稿（落点表、landing↔registry、注入器作用域、安装/回滚）
xiaomusic-tools-pkg/        ← 一键安装包
│  ├─ README.md             ← 安装 / 使用 / 回滚 / FAQ
│  ├─ install.sh            ← 幂等安装（可 --dry-run），默认容器 xiaomusic
│  ├─ uninstall.sh          ← 幂等卸载 / 回滚
│  └─ static/xiaomusic_tools/   ← 拷进容器 /app/xiaomusic/static/ 的整棵静态树
xiaomusic_tools/            ← 静态源（等价于 pkg/static 内那棵，作 diff 参照源；每工具一个子目录）
   ├─ delete-song/          ← 「删除歌曲」二级工具页
   └─ bili-url-download/    ← 「链接下载音频」二级工具页
docs/
   ├─ prd.json              ← 删除链路记录
   ├─ doc_frontend.md       ← 前端壳 / 接入点 / 鉴权资料
   └─ doc_backend.md        ← 删除链路（/delmusic 与名单源）资料
```

## 安装

到 `xiaomusic-tools-pkg/` 目录里执行：

```sh
cd xiaomusic-tools-pkg
./install.sh --dry-run     # 先只读预览会做什么
./install.sh               # 默认容器名 xiaomusic，可用 -c <name> 改
```

装完打开控制面板，主页可见「工具」入口 → 工具卡片页 →「删除歌曲」/「链接下载音频」。

移除（回滚）：

```sh
./uninstall.sh     # 删主页那行 + 移除 /app/xiaomusic/static/xiaomusic_tools 整树
```

更细的说明和 FAQ 见 `xiaomusic-tools-pkg/README.md` 与 `README_draft.md`。

## 说明

- 删除的对象是 `/app/music/download/*.mp3`，由 xiaomusic 既有的 `POST /delmusic` 处理，
  删后经 `/refreshmusictag` 清 tag 残留。tmp/ 与音箱设备端缓存不在范围内。
- 链接下载调 `POST /downloadonemusic` + `GET /download_progress`（xiaomusic 自带，带会话鉴权），
  不改后端代码。抓取依赖容器内 `yt-dlp` 和配置里的 cookie / 代理（`--cookies` / `--proxy` 由 config 注入）。
  遇 HTTP 412 或需登录属运行环境问题，可用 xiaomusic 的「上传 yt-dlp cookie」端点改善。

## 插件商城

这两个工具也提供打包好的 zip，在插件商城里下载：

<https://github.com/molakesizhanfangguangmang/xiaomusic-plugin-store>

商城里是已经打好的插件包（`delete-song-1.0.0.zip`、`bili-url-download-1.0.0.zip`），
配工具区的「上传工具」页用，省去从源码目录手动拷文件。
工具区本体和上传接口在 [xiaomusic-tools](https://github.com/molakesizhanfangguangmang/xiaomusic-tools)。
