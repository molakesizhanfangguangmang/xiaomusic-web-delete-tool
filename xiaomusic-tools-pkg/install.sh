#!/usr/bin/env bash
# =============================================================================
# install.sh — xiaomusic 主页「工具区」(xiaomusic-tools) 一键安装包
#
# 适用：hanxi/xiaomusic v0.6.1 的 Docker 宿主/具备 docker 的宿主机。目标容器默认名
#   xiaomusic（可用 --container/-c 或环境变量 CONTAINER 覆盖）。
# 本包是「纯静态 + 主页尾部插一行」的扁平增强，不改任何 /app/xiaomusic 的 .py、
#   不改设置/conf、不动压缩主干 js。
#
# 作用（对应 deliverables/README_draft.md §2 落点表）：
#   1) 把这包自己的 static/xiaomusic_tools 整棵拷进容器
#      <CONTANIER>:/app/xiaomusic/static/  => 容器内 /app/xiaomusic/static/xiaomusic_tools/
#      （web 即 /static/xiaomusic_tools/…）
#   2) 在 default 主页 /app/xiaomusic/static/default/index.html 的**文件末尾**
#      幂等「追加一行」带唯一标记的 <script> 引用注入器 tools-entry.js：
#        <!--xtools_entry--><script src="/static/xiaomusic_tools/entry/tools-entry.js"></script>
#      该行内唯一 token 为 xtools_entry；只有本脚本写入它，也只按它回滚/判重。
#   3) docker restart 目标容器，让 static/default/index.html 重新被读盘生效。
#
# 幂等 / 回滚安全（story US-005 取最稳处理）：
#   * 重复安装不重插行：主页已含 xtools_entry 标记 → 跳过插行；整树重复拷贝为覆盖式
#     (docker cp 把同名文件叠回) 不报错、无重复注入。
#   * 仅 append 于 EOF，绝不覆盖正文首部；删除(见 uninstall.sh)只删这一整行标记行，
#     恢复主页到「原样 + 仅清注入」，不会误删用户原有内容。
#   * 若在主页上检测到**非本脚本注入**的对 tools-entry.js 的引用（例如按旧版手工文档
#     加过不带标记的同一行）→ 中止并把决定交给人工审；除非带 --force 且操作者自知。
#
# 用法：
#   ./install.sh --dry-run          # 只打印将做什么、不执行（会做只读预检）
#   ./install.sh                    # 真正安装
#   ./install.sh --container myxiaomusic
#   ./install.sh --force            # 越过「主页存在非本注入引用」护栏（操作者自知）
# =============================================================================

set -u

# ---- 常量：本包自述标记（两脚本共享同一字符串，别改这半句以免与已布主页失配）----
readonly MARKER_TOKEN='xtools_entry'
readonly INJECT_LINE='<!--xtools_entry--><script src="/static/xiaomusic_tools/entry/tools-entry.js"></script>'

# 变量主路径
readonly PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly TREE_SRC="$PKG_DIR/static/xiaomusic_tools"
# 容器内 static 根与首页路径（v0.6.1 布局；default 皮肤主页被 bake 在镜像里，故要改的是容器内那份）
readonly CONT_STATIC='/app/xiaomusic/static'
readonly CONT_DEF_INDEX="$CONT_STATIC/default/index.html"

CONTAINER="${CONTAINER:-xiaomusic}"
DRY_RUN=0
FORCE=0

# ---- 输出辅助 ----
info() { printf '\033[0;36m[info]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
用法: install.sh [选项]

把本包 static/xiaomusic_tools 拷进目标容器并幂等给 default 主页尾部插一行注入入口。

选项:
  -c, --container <名>   目标 Docker 容器名（默认: xiaomusic；亦可设环境变量 CONTAINER）
      --dry-run           只打印将执行的动作并只读预检，不改任务何内容后退出(0)。
      --force             越过「主页里检测到非本注入的 tools-entry 引用」护栏，继续插行。
                          （确认为人工/旧版所加时才用；操作者须自知不覆盖他人改动。）
  -h, --help             显示本帮助。
EOF
}

# ---- 参数解析 ----
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--container) CONTAINER="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --force)        FORCE=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) err "未知参数: $1"; usage; exit 2 ;;
  esac
done

[ -n "$CONTAINER" ] || { err "container 名不能为空"; exit 2; }

# ---- 预检 ---------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  err "本机找不到 docker 命令。此安装包需跑在具备 Docker 的宿主机上。"
  err "请先在宿主安装/启用 Docker 后重试（本包为纯静态增强，未做任何写入即退出）。"
  exit 1
fi

# 判定目标容器真实运行中（只读，不产生副作用）
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  err "找不到正在运行的 Docker 容器「$CONTAINER」。"
  err "  先用: docker ps  确认容器（默认名 xiaomusic 可能不同）；"
  err "  再用: ./install.sh --container <实际名>   重试；或用环境变量 CONTAINER=<名>。"
  err "本操作未做任何写入（含 --dry-run 也一样只在预检后清醒退出）。"
  exit 1
fi

# 落点权限预检（尽力而为，属于保守护栏；exec 失败不硬拦，交给 docker cp 自报错）
_perm_precheck() {
  docker exec "$CONTAINER" sh -c \
    "test -d '$CONT_STATIC' && test -w '$CONT_STATIC'" >/dev/null 2>&1 && return 0
  warn "无法确认容器内 $CONT_STATIC 是否可写（多半是镜像缺 sh 或非 root 容器）。"
  warn "安装会继续并让 docker cp 自行报告真正错误；若权限不足将在此失败且不做主页改动。"
  return 0
}

# ---- 动作定义（dry-run 只 describe 不 run；apply 才真的执行）------------
say_run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    info "将执行: $*"
  else
    eval "$*"
  fi
}

# 1) 整棵静态树拷入（覆盖式、幂等）
[ -d "$TREE_SRC" ] || { err "缺少包内 static 目录: $TREE_SRC（请勿单独移动 install.sh）"; exit 3; }

# 2) 主页尾部插行前，先把现内容拉到宿主机 tmp 分析
tmpd=''
_cleanup() { [ -n "$tmpd" ] && rm -rf "$tmpd"; }
trap _cleanup EXIT

inject_index() {
  # 返回码约定：0=无需/已处理好；2=护栏拦下需 --force或人工
  local host_src
  if [ "$DRY_RUN" -eq 1 ]; then
    info "主页检测: docker cp $CONTAINER:$CONT_DEF_INDEX 到临时目录后读取判断以下状态"
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    # dry-run 下不实际拉文件：仅说明将做插行（真实状态在 apply 时决定）
    info "若主页未含 $MARKER_TOKEN 且无非本注入引用：在 $CONT_DEF_INDEX 末尾追加一行:"
    printf '        %s\n' "$INJECT_LINE"
    info "写回: docker cp <tmp>/index.html $CONTAINER:$CONT_DEF_INDEX"
    return 0
  fi

  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/${MARKER_TOKEN}.XXXXXX")" || { err "mktemp 失败"; return 4; }
  host_src="$tmpd/index.html"

  if ! docker cp "$CONTAINER:$CONT_DEF_INDEX" "$host_src" >/dev/null 2>&1; then
    err "拉取主页 $CONT_DEF_INDEX 失败（多半未存在？）。首页文件已在 bake 进镜像，若确缺失请人工核对。"
    err "静态树可能已拷入，但主页入口未注入。中止主页改动（不改任何正文）。"
    return 4
  fi

  # 首页必须像是一份 html，避免在非预期文件上 append 破坏内容
  if ! grep -qi '<html' "$host_src"; then
    err "主页 $CONT_DEF_INDEX 内容不像 HTML(<html 缺失)，疑似非预期文件/已被大改。"
    err "本脚本只在 html 首页末尾幂等插一行，为避免覆盖他人改动在此中止。"
    if [ "$FORCE" -eq 1 ]; then
      warn "--force 已给：虽主页缺失 <html>(HTML 形态护栏被刻意越过)，仍照常继续插行（操作者确认无冲突）。"
    else
      err "如确认为测试文件或你已知道自己在做什么，可加 --force 强制继续。"
      return 2
    fi
  fi

  # 状态判定
  if grep -q "$MARKER_TOKEN" "$host_src"; then
    info "主页已含本工具标记($MARKER_TOKEN)，幂等跳过插行（重复执行无副作用）。"
    return 0
  fi

  if grep -q 'tools-entry\.js' "$host_src"; then
    warn "主页已引用 /static/xiaomusic_tools/entry/tools-entry.js，但**不带本脚本专属标记**"
    warn "（可能是按旧版 README 手工加、或他人加的引用）。为避免插出重复入口/覆盖他人改动："
    if [ "$FORCE" -eq 1 ]; then
      warn "--force 已给：照常追加本脚本标记行（操作者确认无冲突）。"
    else
      err "中止主页插行。请人工审阅该行若确属本工具残留可先手动删除再重跑；"
      err "或确认无冲突后加 --force 继续（此时本脚本会再 append 一条带标记行）。静态树不受影响。"
      return 2
    fi
  fi

  # 追加：保证文件以单个 \n 结尾后再写一整行，避免粘连/前导空行污染
  if [ -s "$host_src" ] && [ "$(tail -c1 "$host_src" | od -An -tx1 | tr -d ' \n')" != '0a' ]; then
    printf '\n' >> "$host_src"
  fi
  printf '%s\n' "$INJECT_LINE" >> "$host_src"
  info "已在 $CONT_DEF_INDEX 末尾追加一行(标记 $MARKER_TOKEN)。"

  if ! docker cp "$host_src" "$CONTAINER:$CONT_DEF_INDEX" >/dev/null 2>&1; then
    err "写回主页失败（docker cp 返回非 0）。请检查容器 $CONTAINER 磁盘/权限。"
    err "提示：本地临时备份仍在 $host_src；未做 restart，可在容器内核对后手动放回。"
    return 4
  fi
  info "已写回容器内主页。"
  return 0
}

# ============================ 主流程 ====================================
info "目标容器: $CONTAINER   (dry-run=$DRY_RUN force=$FORCE)"
_perm_precheck

# 动作 1：拷整棵 static 树
if [ ! -d "$TREE_SRC" ]; then
  err "包内未找到 static/xiaomusic_tools 目录；install.sh 必须和 static/ 在一起。"
  exit 3
fi
say_run "docker cp '$TREE_SRC' '$CONTAINER:$CONT_STATIC/'"

# 动作 2：主页幂等插行
if ! inject_index; then
  rc=$?
  err "主页插行阶段未完成(rc=$rc)。静态树若已拷入属宽松副作用（纯新增同名覆盖，可重跑修复）。"
  exit "$rc"
fi

# 动作 3：重启使首页重新读盘
say_run "docker restart '$CONTAINER'"

if [ "$DRY_RUN" -eq 1 ]; then
  info 'dry-run 结束：以上为将执行的命令。未做任何写入。'
  exit 0
fi

info "完成。刷新主页 http://<host>:<port>/static/default/index.html 即可见「工具」入口；"
info "确认后点主页「工具」，或直接访问工具一层页 /static/xiaomusic_tools/index.html（裸目录 xiaomusic 不自动列目录会 404）。卸载请用同目录 ./uninstall.sh。"
exit 0
