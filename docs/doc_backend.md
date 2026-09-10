# US-002 后端删除链路只读研究报告 (doc_backend)

目标容器：`xiaomusic`（镜像内 xiaomusic 单进程，工作目录 `/app`，启动参数 `["/app/xiaomusic.py"]`）。
范围：回答「工具页删『已下载/已缓存歌』」能否纯靠既有接口、以及删除真正动到哪里、会留什么残留。
全部只读（不含任何写容器/HTTP 副作用）。源码只读副本：`research_backend/*.py`。

---

## §0 实际执行的关键只读命令（节选，均为 docker exec … cat/grep/sed / docker inspect，未做任何写操作）

```
docker inspect xiaomusic --format '{{json .Mounts}}'
  -> [{"Type":"bind","Source":"<music_root>/music","Destination":"/app/music","RW":true,...}
      ,{"Type":"bind","Source":"<music_root>/conf","Destination":"/app/conf","RW":true,...}]
docker inspect xiaomusic --format 'Name={{.Name}} WorkingDir={{.Config.WorkingDir}}'  -> Name=/xiaomusic WorkingDir=/app
docker inspect xiaomusic --format '{{json .Args}}' -> ["/app/xiaomusic.py"]
docker exec xiaomusic grep -nE '@router.post\("/delmusic"\)|...' /app/xiaomusic/api/routers/music.py /app/xiaomusic/api/models.py 等
docker exec xiaomusic cat /app/xiaomusic/api/routers/music.py            (快照 research_backend/routers_music.py)
docker exec xiaomusic cat /app/xiaomusic/api/models.py                   (快照 research_backend/api_models.py)
docker exec xiaomusic cat /app/xiaomusic/xiaomusic.py                    (快照 research_backend/xiaomusic.py)
docker exec xiaomusic cat /app/xiaomusic/music_library.py                (快照)
docker exec xiaomusic cat /app/xiaomusic/config.py                       (快照)
docker exec xiaomusic cat /app/xiaomusic/file_watcher.py  /app/xiaomusic/const.py   (快照)
docker exec xiaomusic cat /app/xiaomusic/utils/file_utils.py  /network_utils.py  /api/routers/file.py /playlist.py (快照)
ls <music_root>/music/{download,cache,tmp}  （宿主音乐根挂载点只读列目录）
docker exec xiaomusic cat /app/music/cache/tag_cache.json                (实时只读当前 tag 缓存内容)
```
研究只读副本存放：loop 内 `research_backend/`。

---

## §1 删除链路语义：路由端点 → service 实现 → 真删文件位置 → 副作用面

### 1a. HTTP 端点是 `/delmusic`（POST），位于 `api/routers/music.py`

源码 `music.py:296-301`（该文件体积 347 行，此处为整个方法）：
```python
@router.post("/delmusic")
async def delmusic(data: MusicItem):
    """删除音乐"""
    log.info(data)
    await xiaomusic.del_music(data.name)
    return "success"
```
- 请求体 `data` 用 pydantic `MusicItem`（`api/models.py:31`，§2 详解）。
- `router = APIRouter(dependencies=[Depends(verification)])`（`music.py:26`）→ 整块路由受统一会话鉴权保护。
- 同名 if 分支在 `/app/xiaomusic/api/routers/__init__.py` 的 `register_routers(app)` 注册，无额外 URL 前缀，即真实 URL 是 `POST /delmusic`，与 US-001 中前端调用一致。

### 1b. service 实现是 `XiaoMusic.del_music`，位于 `xiaomusic.py`（不是 api/routers，也不是 music_library）

`xiaomusic.py:364-378` 完整原文：
```python
async def del_music(self, name):
    filename = self.music_library.get_filename(name)
    if filename == "":
        self.log.info(f"${name} not exist")
        return
    try:
        os.remove(filename)
        self.log.info(f"del ${filename} success")
    except OSError:
        self.log.error(f"del ${filename} failed")
    # 重新生成音乐列表
    self.music_library.gen_all_music_list()
    self.update_all_playlist()
```

补充：还有一个语音命令入口 `cmd_del_music(did, arg1)` 调 `self.del_music(name)`（active_cmd 含 `cmd_del_music`，删除受 `enable_cmd_del_music` 开关）。与 /delmusic 殊途同归。

### 1c. `name → 真实文件` 的解析在 `MusicLibrary.get_filename`，`music_library.py:664-680`

```python
def get_filename(self, name):
    """音乐名称 -> 文件路径，不存在返回空"""
    if name not in self.all_music:
        log.info("get_filename not in. name"); return ""
    filename = self.all_music[name]
    if os.path.exists(filename): return filename
    return ""
```
要点：
- **`name` 不是路径，而是音乐库的“键”**（文件名去扩展名的 basename），`self.all_music[name]`（`music_library.py:47` 初始化，`:101` gen_all_music_list 里 `self.all_music[name] = file`，file 是 scan 出的绝对完整路径）。
- `get_filename` 只查**内存态** `all_music`（每次 gen 重建一次），外加 `os.path.exists` 二次确认。`all_music` 里没有该名 → 返回 `""` → `del_music` 只是打日志返回，**静默成功、不报错不删**。

### 1d. 真实文件落在哪个目录（持久卷 / tmp）

关键唯读证据（宿主机侧 docker inspect mounts + 容器内 ls）：
- `/app/music`（音乐根目录） = bind 持久卷，宿主机 `<music_root>/music`（RW）。
- `/app/conf` = 另一 bind 卷 `<music_root>/conf`。
- 容器 WorkingDir=/app，配置里 `music_path`/`download_path`/`cache_dir`/`temp_path` 皆为“相对 /app”的字符串（`config.py:96-100`），因此解析为绝对路径在 `/app/music/...`：
  - `download_path`(默认 `os.getenv("XIAOMUSIC_DOWNLOAD_PATH","music/download")`)  → `/app/music/download` = 宿主 `<music_root>/music/download`（**持久、非 tmp**）
  - `cache_dir`(默认 `music/cache`)   → `/app/music/cache`（tag_cache.json、picture_cache）
  - `temp_path`(默认 `music/tmp`)     → `/app/music/tmp`
- 宿主侧事实清单（只读 ls）：
  ```
  <music_root>/music/download/ -> “不回去可以主题曲.mp3…弱水三千.mp3…至尊宝帝王.mp3”（9 首整首 mp3，~几 MB 到 39MB）
  <music_root>/music/tmp/      -> 一堆 16KB..30KB 的 {md5}.mp3（哈希小片段）
  <music_root>/music/cache/    -> tag_cache.json(+bak)、cache_songs/、picture_cache/
  ```
- 故 `del_music(name)` 的 `os.remove(filename)` 如果目标是已下载歌曲，删的就是 **`<music_root>/music/download/<name>.mp3`（bind 持久卷，删了就真没了，不回收站）**；get_filename 返回的 filename 就是 download_path 下的真正完整路径。

### 1e. 副作用面（del_music 到底动哪些）

删掉真实文件后执行两次“重建”，**不会**主动清 tag_cache 等条目：
1. `self.music_library.gen_all_music_list()`（music_library.py:101）→ 会把 `self.all_music` 与 `self.playlist_music_urls` 清空并重扫。
   - `music_library.py:101-202`：清空 → `traverse_music_directory(self.config.music_path, depth, exclude_dirs, ...)`（file_utils.py:44，os.walk、剔除 exclude dir）→ 逐文件 `name=basename去掉扩展名`, `self.all_music[name]=完整路径`。
   - self 重建固定结构 music_list：`所有歌曲/所有电台/全部/下载/其他/最近新增` + 每个目录一组，如 download/ 目录分到键“下载”。
   - **本质：下一轮 /musiclist 就不再包含被删的歌**（重扫自然移走旧条目，见 §4）。
   - 末尾 `try_gen_all_music_tag()` 只对**当前存在的**歌曲“缺则补”标签。
2. `self.update_all_playlist()`（xiaomusic.py:611-613）→ 替每个音箱设备刷新当前歌单。

**副作用面总结**：真正被 `os.remove` 的只有由 name 唯一解析出的那个下载文件（持久卷 <music_root>/music/download/xxx.mp3）。**不删**：`cache/tag_cache.json` 里的该歌条目、`picture_cache/` 里该歌图片、`music/tmp/` 哈希片段、音箱端已缓存的 URL。残留细节见 §4/§6。

---

## §2 请求模型字段（models.py 全文 79 行，pydantic BaseModel）

先列与删除/取列表有关的模型：

```python
# api/models.py:31
class MusicItem(BaseModel):
    name: str                                    # 唯一真正与删除有关：必填，字符串，无 default
# api/models.py:57
class DownloadOneMusic(BaseModel):
    name: str = ""                               # 下载单曲的可选命名（同名删除也用这语义? 否——/delmusic 用 MusicItem）
    url: str
    dirname: str = ""
    playlist_name: str = ""
# api/models.py:71
class PlayListMusicObj(BaseModel):
    name: str = ""                               # 歌单名
    music_list: list[str]                        # 歌曲名列表
# api/models.py:77-79
class MusicInfosQuery(BaseModel):
    name: list[str]                              # 必填：歌曲名数组
    musictag: bool = False
# api/models.py:19-30
class MusicInfoObj(BaseModel):
    musicname: str
    title/artist/album/year/genre/lyrics: str   # 默认""
    picture: str = ""                            # base64
# api/models.py:44
class DidPlayMusic(BaseModel):
    did: str
    musicname: str = ""
    searchkey: str = ""
```
字段语义：
- `MusicItem.name`：**音乐库名字键 = 相对 download/music 目录的“文件名去扩展名 basename”**（不是绝对路径，也不含目录分隔符“子目录/xxx”，更不含扩展名）。前端“展示后删除”应从 /musiclist 返回值取这些键名直接回传。
- 同 basename 的歌会互相碰撞覆盖：gen_all_music_list 里 `self.all_music[name] = file` 后写覆盖（注释“歌曲名字相同会覆盖”）。若 download/ 与 music/ 其它子目录有同名歌，最终 only 保留后者解析到的那一个物理文件可被删；值得在 §5 提示 UI 不要展示裸名去误导。
- `MusicInfosQuery.name` 是数组，同是名字键；`/musicinfos`(POST, L275) 对每个名字跑 `get_music_url` 返回 `{"name","url",(tags)}`。

**“删除前取列表”该传什么参数**：直接对 `/delmusic` POST body `{"name": "<返回键名，不带扩展名>"}` 即可；如需先在 UI 展示可播链接 → 对列表键名数组 POST `/musicinfos` body `{"name":[...]}`（见 §3）。

---

## §3 响应 / 成功判定；取列表用 /musiclist vs /musicinfos；最可靠的“已下载已缓存”清单源

### delmusic 返回与校验
- 路由挂 `Depends(verification)`（统一会话鉴权）：未带合法 cookie/凭证会 401/403 —— “前端口校验”即此。
- 成功返回**裸字符串 `"success"`**（端点在最后 `return "success"`，FastAPI 会发出 `"success"`），无 “ret/OK” 包壳。
- **失败不抛异常**：`get_filename` 返回空或 `os.remove` 抛 OSError 都仅 log（`xiaomusic.del_music`内容），HTTP 依旧 200 返回 `"success"`。⇒ 工具页不能拿响应当“真删了”；要判定成功，最好删除后重新取一次列表、看该键是否消失（且最好用 `/musicinfos` 对它探活链路/用物理 url HEAD 404）。这是本报告给 UI 的关键提示。

### 数据源对比（README 佐证以下每个端点 file+行）
| | `/musiclist` (GET, music.py:236) | `/musicinfos`(POST body) music.py:275 / (GET) :258 | 静态文件路由 `/music/{path}` (file.py:956, GET) |
|---|---|---|---|
| 返回 | `music_library.music_list`（dict，值为歌名字键数组） | 每名 `{"name","url"}` | 文件本身 |
| 能拿到的“名称键” | ✔ 正是 /delmusic 需要的 name 键（含嵌套歌单/browse grouping） | name 单纯透传 | 无（只给字节） |
| 能不能区分“文件确实在盘上” | 二次 read：重建后仍在列表=在盘（见 §4） | url 为空/404 间接判断 | HEAD/GET 404=没了 |
| 用途 | **首选：展示名单的“叶子键”** | 改名/播放前探 url | 删除后作“存在性”复核 |

- `/musiclist` 返回的是 `self.music_list`（`music_library.py:1132-1134 return self.music_list`；结构在 gen_all_music_list 里构建）。top 层键固定：`所有歌曲/所有电台/全部/下载/其他/最近新增`+自定歌单+每个子目录键。download/ 目录的键在 music_list 里的重命名是 **“下载”**（`music_library.py:134` 把 `download_path 的 dir 名`（即 `download`）rename 名“下载”）。⇒ **“展示所有已下载/已缓存歌”最贴近的现成来源：`GET /musiclist` 里取键 `"下载"`（及其它子目录键）的值——值是下载区当前扫描态的名字键**。
- `/musicinfos` 给出 `url`（经 `get_music_url`→`_get_file_url`，music_library.py:1177 / 1351 / 1366）。本地歌的播放 url 形如 `http://<hostname>:<public_port>/music/<strip music_path 的剩余相对路径>`（strip 根 music_path 后余 `download/xxx.mp3`），即借助 file.py:956 的静态路由提供访问键。
- 单曲浏览接口方面，**没有一个“列 download/ 目录全部文件名”的只读 GET 接口**。可枚举的路由全部 list 可见（routers_file 的路由头清单见 grep）：树形浏览能力只在 /musiclist；download 区只有 `/music/{file_path}`、`/download_progress`(任务状态)、以及一堆 POST(pause/resume/delete/stop_download 等管理动作)。若 UI 要“旁证磁盘上还剩哪些文件、而无重扫延迟”，唯一纯读法是 HTTP/HEAD `/music/download/<name>.mp3`（404→真没了）。结论点此：**文件名/列表键的数据源 = /musiclist（“下载”键），可当主力**。

---

## §4 file_watcher / tag_cache 联动（全只读逻辑推演）

### 目录扫描触发点
- 启动：`xiaomusic.start_file_watch()` 在 `enable_file_watch` 为真时创建 `FileWatcherManager(config,log,on_change_callback=self._on_file_change)`（xiaomusic.py:236-242），递归监听 `config.music_path`（file_watcher.py FileWatcherManager.start 内 `observer.schedule(self._file_watch_handler, self.config.music_path, recursive=True)`）。
- 文件增/删/移（音乐扩展名）→ debounce(`file_watch_debounce`) → `_on_file_change`：
  ```python
  # xiaomusic.py:244-248
  def _on_file_change(self):
      self.music_library.gen_all_music_list()
      self.update_all_playlist()
  ```
- del_music 里 `os.remove` 本身就会**再触发一轮相同的 `_on_file_change` regen**——因此删除后名单收敛是“双保险”，但仍是“异步/防抖 + 下一次 rescan”才从列表剔除。

### 删除后旧条目如何
- gen_all_music_list **清空后全量重扫**（`self.all_music = {}` 再 os.walk music_path）→ 只要物理文件不在，下次扫描生成的 /musiclist 即无该键（正常情形延迟=一次 debounce+regen）。
- 潜在旧条目残留：只有**内存态**名字在 gen 后才消失；`cache/tag_cache.json` 与 `self.all_music_tags` 的内存标签**不会因该歌文件被删而主动删条目**（见 tag 写作逻辑）。因此“删除→旧歌仍在 tag 缓存”是常态（§4 末尾解释影响）。

### tag_cache.json 落点与结构
- `config.tag_cache_path = os.path.join(cache_dir,"tag_cache.json")`（config.py:374-378）= `/app/music/cache/tag_cache.json` = 宿主 `<music_root>/music/cache/tag_cache.json`。
- 数值型内容由 JSON 固化（只读实录，例如）：
  ```json
  { "弱水三千": {"title":"","artist":"","album":"","year":"","genre":"","picture":"","lyrics":"","duration":265.92}, "琵琶行": {...}, ... }
  ```
- 写入位置：`_gen_all_music_tag`（music_library.py:1000 附近循环 `all_music_tags[name]=extract_audio_metadata(...)`；`key not in all_music_tags` 才补；最后一次性 `self.all_music_tags=…` + `try_save_tag_cache()` dump 整个 dict），以及 `set_music_tag`/`api setmusictag`(music.py:293→782) 时对单首要写的 item `self.all_music_tags[name]=tags; try_save_tag_cache()`。
- **删除歌之后**：del_music 的 regen → `try_gen_all_music_tag()` 只“缺则补”，从不删除不在盘的 name 键 → tag_cache.json 里该 name 的 title/duration/picture 条目**原样留存**，直到调 `POST /refreshmusictag`（music.py:322→music_library.refresh_music_tag，其把 tag_cache.json 整个 dump `{}` + `self.all_music_tags={}` + 重建）才会洗掉。
- `.tag`/目录项残留会体现为什么：前端若从“音乐信息/标签”这类页去给这个名字生成 URL，`get_music_url`→`get_filename`→name 已不在内存 all_music → url 为空；而 tag 页按 tag_cache 里的旧键展示“歌在”，点开却空 URL。⇒ **工具页应提示用户：删除后用「刷新音乐标签」入口（/refreshmusictag）清理 tag 残留会更整洁；否则 tag 缓存里短暂仍有该歌名的元数据。**

---

## §5 判定结论

### (a) 纯靠前端调既有接口能否达成“删除某首已下载歌曲”？
**基本可以，成熟方案 = 两步纯 GET+POST 既有接口，零后端改动：**
1. `GET /musiclist`（music.py:236）→ 取键 `"下载"`（download/ 目录组的名字键数组；必要时过滤掉明显是 hash/非真实 file 的 temp 名字）。
2. 对每个想删的名字键 POST `/delmusic`，body `{"name":"<名字键>"}`（music.py:298，MusicItem）。
3. 结果校验：该端点对“名字不存在/删失败”不抛错、一律回 `"success"`，因此工具页删除后应**重新 `GET /musiclist` 确认该键消失**；若想更贴近“确被物理删”，可对 `/music/download/<name>.mp3` HEAD/GET 拿 404（file.py:956）。
4. （可选顺带 `/musicinfos` 只读探活 url，供 UI 展示试听、并在 delete 前双确认它 `url` 非空）。
可行前提唯一注意点：**名字键= basename 去扩展名**，同 basename 撞名会覆盖而只能删到其中一份，UI 展示时最好用“分组/路径上下文”肉眼区分，实删键却只能是裸名（产品层可接受的现状）。
⇒ 结论 (a) = **能**，且**无需改动后端**；删的是 `<music_root>/music/download` bind 持久卷下真实 mp3（非 tmp，非恢复）。

### (b) 若仍想要“最可靠”清单，给出最少后端只读改动定位（只命名，不实现、不动手）
候选方案命名与定位：
- 在 `xiaomusic.config.Config.download_path`（config.py:97）解析出的目录（/app/music/download）上新增一个**只读** GET（类比 file.py:956 `/music/{path}`；或在 `music.py` router L244 `/musiclist` 旁），命名建议 `routers_file` 内加 `GET /api/files/list?path=download`：沿 `/usr` os.listdir/`traverse_music_directory` 返回**完整文件名数组（含扩展名/子目录相对路径）**，供 UI 直接在磁盘态消歧同 basename、并绕过 rescan。
- 这没有本质必要——`/musiclist` 的“下载”键已能完成删除动作；此接口仅用于“想列举磁盘真实全部（含缓存/tag）意义上的文件”。特此注明 §5(b)只是定位，不实现。

---

## §6 备注:存量超出删除范围的现状证据(出 /download 的 *.part 等、以及 hash 残留物、及音箱端缓存不被删)

只读事实（宿主机/vol1 ls + 源码常量）：
- SUPPORT_MUSIC_TYPE 常量（const.py:2-9）只包括 `.mp3/.flac/.wav/.ape/.ogg/.m4a/.wma`。
- 网络正片下载由 `download_playlist/download_one_music`(network_utils.py:~172/206) 的 yt-dlp 落盘到 `config.download_path`(/app/music/download)，`-o` 模板文件名最终是 `name.mp3` 等——**本仓库下载不会出现 `.part`（那是 yt-dlp 内部过程文件在 download_path 下的临时中间态**.但系统可以真实存在中途 .part），delmusic 机制也不感知此类扩展名。
- 真正“下载目录之外”的缓存区现状（只读 ls 实录）：
  - `<music_root>/music/tmp/`：19 个 `{md5(or hash)}.mp3`，每个 16KB~30KB = 边播缓存/转码中间态。它对应 file.py `/music/temp/…`（music_file 路由 if path.startswith("temp/") 走 `config.temp_path`，见 file.py:956-门内），以及 config 的 remove_id3tag/convert 流程会写 temp。而**音乐列表扫描 exclude_dirs 默认含 "tmp"（config.exclude_dirs="...@eaDir,tmp"，及 `get_exclude_dirs_set`/file_utils os.walk 剪除）→ tmp 下的 hash 歌从不进 /musiclist，delmusic 也够不着**（name 不在 all_music），故这些属于“音箱端/中间缓存残留”，**不在删除工具的覆盖预期内**——工具页应明确只覆盖 download 区真实下载。
  - `music/cache/`（音箱端“截胡缓存” cache_dir + picture_cache + tag_cache.json）：播放链 `get_music_url`(music_library.py:1177/_get_web_music_url) 对网络歌做了“小爱端缓存命中/死链”逻辑，缓存在 `_extract_cache_path_from_url`(817)→cache_dir/cache_songs。此区同样独立于 delmusic，删 download 不会顺带清这里。
- tag 残留已细说于 §4；picture_cache（save_picture_by_base64 写入 config.picture_cache_path= cache/picture_cache）。
- 结束语：delmusic 的**删除范围严格= name 解析出的单个真实 mp3（download_path 持久卷内）** + 触发 rescan/playlist 刷新；tmp/哈希、cache/tag_cache、音箱端 URL/时长缓存、`.part` 中间态均不在其内。任何清理它们均需明确另走 `/refreshmusictag`（仅洗 tag_json）或未来再议，不属本次只读范围。

---

## 红线自检

- 全部容器访问均为只读命令：`docker inspect`、`docker exec <cat|sed|grep|find|ls|wc>`。未对容器执行任何写文件 / docker cp(出) 外的操作、无 commit、无 restart/stop/start、无 rm/mv。
- 未调用任何删改型 HTTP 方法（POST/DELETE/PUT/PATCH 一律未发；也未发 GET 到会触发下载/清理或副作用的地址）。
- `docker cp` 外无任何“写容器”；所有输出仅落到本 loop：`research_backend/` 快照 + 本 doc_backend.md。
- progress.txt 仅在其末尾追一段文字（先读后追加），落盘唯一新增 = 本 loop。

完成于 2026-09-10。
