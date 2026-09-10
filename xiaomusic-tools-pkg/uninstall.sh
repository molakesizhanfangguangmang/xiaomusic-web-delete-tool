#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — 卸载 / 回滚 xiaomusic-tools（对应 install.sh 的逆操作）
#
# 幂等、只清「本包自己的东西」：
#   1) 若 default 主页 $CONT_DEF_INDEX 含本工具专属标记行 xtools_entry，
#      就**精确删除那一整行**（line 按 token 匹配），把其余正文原样写回 ——
#      这样恢复后的主页 == 安装前正文（只清了注入，不误删用户已有内容）。
#   2) 删除容器内 static/xiaomusic_tools 整棵（这是本包纯新增的目录）。
#   3) docker restart 目标容器让首页重新读盘。
#
# 不会做的事：不碰 /app/xiaomusic 下的任何 .py / 设置 / conf / 其它皮肤。
#
# 幂等说明：目录已不在 且 主页已无标记行 => "nothing to remove"，正常退出 0。
#
# 用法：
#   ./uninstall.sh --dry-run
#   ./uninstall.sh
#   ./uninstall.sh --container myxiaomusic
# 注：若主页存在**不带本标记**（手工/旧版）的 tools-entry.js 引用，本脚本不会去删它
#   （避免动他人内容），只会移除本包目录并提示你按需手工清那一行。
# =============================================================================

set -u

readonly MARKER_TOKEN='xtools_entry'
readonly PKG_TREE='xiaomusic_tools'

CONTAINER="${CONTAINER:-xiaomusic}"
DRY_RUN=0
CHANGED=0   # 本次是否真的改了什么（用于决定是否要 restart）

CONT_STATIC='/app/xiaomusic/static'
CONT_DEF_INDEX="$CONT_STATIC/default/index.html"
CONT_TREE="$CONT_STATIC/$PKG_TREE"

info() { printf '\033[0;36m[info]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
用法: uninstall.sh [选项]

移除首页注入的“工具”入口行 + 删除容器内 static/xiaomusic_tools 目录（幂等）。

选项:
  -c, --container <名>   目标 Docker 容器名（默认: xiaomusic；亦可设 CONTAINER）
      --dry-run          只打印将做的动作与只读预检，不改变任何内容。
  -h, --help             显示本帮助。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--container) CONTAINER="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) err "未知参数: $1"; usage; exit 2 ;;
  esac
done
[ -n "$CONTAINER" ] || { err "container 名不能为空"; exit 2; }

if ! command -v docker >/dev/null 2>&1; then
  err "本机找不到 docker 命令。卸载需跑在具备 Docker 的宿主机上。"
  err "本操作未做任何写入即退出。"
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  err "找不到正在运行的 Docker 容器「$CONTAINER」，无法在容器内卸载。"
  err "  若该容器已不存在（重建/删掉），可忽略本目录残留或直接删除包目录；容器侧已无注入文件。"
  err "未做任何写入退出（含 --dry-run）。"
  exit 1
fi

say_run() {
  if [ "$DRY_RUN" -eq 1 ]; then info "将执行: $*"; else eval "$*"; fi
}

# ---- 1) 主页标记行移除（精确，只需按 token 删整行，多余内容原样保留）----
tmpd=''
_cleanup() { [ -n "$tmpd" ] && rm -rf "$tmpd"; }
trap _cleanup EXIT

remove_index_marker() {
  local host_src
  if [ "$DRY_RUN" -eq 1 ]; then
    info "主页 $CONT_DEF_INDEX：若含 $MARKER_TOKEN 将删除该一整行并 docker cp 写回"
    return 0
  fi
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/xt-rm.XXXXXX")" || return 4
  host_src="$tmpd/index.html"
  if ! docker cp "$CONTAINER:$CONT_DEF_INDEX" "$host_src" >/dev/null 2>&1; then
    err "拉取主页失败（可能从来未被注入/文件不存在），跳过首页行移除。"
    return 0
  fi

  if ! grep -q "$MARKER_TOKEN" "$host_src"; then
    info "主页无本工具标记($MARKER_TOKEN)，无需移除行。"
    return 0
  fi

  # 只删匹配整行（awk 精确到行），其余行原样保留。
  awk -v t="$MARKER_TOKEN" 'index($0,t)==0{print}' "$host_src" > "$host_src.new" || return 4
  mv "$host_src.new" "$host_src"

  if ! docker cp "$host_src" "$CONTAINER:$CONT_DEF_INDEX" >/dev/null 2>&1; then
    err "写回处理后的主页失败。请检查容器权限/磁盘。临时文件在 $host_src。"
    return 4
  fi
  info "已移除主页中本工具标记行并写回（其余正文原样）。"
  CHANGED=1
  return 0
}

# ---- 卸载主流程 --------------------------------------------------------
info "目标容器: $CONTAINER   (dry-run=$DRY_RUN)"

if ! remove_index_marker; then
  err "主页标记行移除失败，中止后续（目录暂不删除）。"
  exit 4
fi

# ---- 2) 删除容器内整棵 xiaomusic_tools（本包纯新增目录）----
if docker exec "$CONTAINER" sh -c "test -e '$CONT_TREE'" >/dev/null 2>&1; then
  say_run "docker exec '$CONTAINER' rm -rf '$CONT_TREE'"
  info "若目录存在已删除；若不存在 rm -rf 静默无碍。"
  CHANGED=1
else
  if [ "$DRY_RUN" -ne 1 ]; then
    info "容器内目录 $CONT_TREE 已不存在（幂等空跑）。"
  fi
fi

# 3) 仅在确实改了什么（删了标记行或删了目录）才重启让首页重新读盘；
#    干净空跑则不动容器，保持"nothing to remove -> 无副作用"。
if [ "$CHANGED" -eq 1 ]; then
  say_run "docker restart '$CONTAINER'"
else
  info "未改动任何内容（首页无标记且目录已不在），跳过 restart。"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  info 'dry-run 结束：以上为将执行的命令，未做任何写入。'
  exit 0
fi
info "卸载完成。主页已恢复为安装前正文（仅清掉注入行）；工具入口与目录已移除。"
exit 0
