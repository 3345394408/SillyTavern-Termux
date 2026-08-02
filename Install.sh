#!/usr/bin/env bash

# SillyTavern 1.14.0 Termux 轻量安装与管理脚本
set -u

SCRIPT_VERSION="1.6.0"
SCRIPT_BUILD=2026080316
ST_VERSION="1.14.0"
REPO="https://github.com/SillyTavern/SillyTavern.git"
SELF_UPDATE_URL="https://raw.githubusercontent.com/3345394408/SillyTavern-Termux/main/Install.sh"
SELF_UPDATE_API="https://api.github.com/repos/3345394408/SillyTavern-Termux/contents/Install.sh?ref=main"

ST_DIR="${HOME}/SillyTavern"
BIN_DIR="${HOME}/.local/bin"
MANAGER="${BIN_DIR}/st-manager"
STATE_DIR="${HOME}/.config/st-manager"
INITIALIZED="${STATE_DIR}/initialized"
BASHRC="${HOME}/.bashrc"
BASH_PROFILE="${HOME}/.bash_profile"
ZSHRC="${HOME}/.zshrc"
AUTO_BEGIN="# >>> SillyTavern Termux Manager >>>"
AUTO_END="# <<< SillyTavern Termux Manager <<<"

# 运行时采用均衡设置：避免过低的内存/线程限制导致启动失败或响应迟缓。
# 低内存设备可在启动前执行：export ST_NODE_HEAP_MB=512
NODE_HEAP_MB="${ST_NODE_HEAP_MB:-768}"
UPDATE_STATUS="等待检查"
SELF_UPDATE_ARGS=()

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; RESET=''
fi

info()  { printf "%b%s%b\n" "$CYAN" "$*" "$RESET"; }
ok()    { printf "%b%s%b\n" "$GREEN" "$*" "$RESET"; }
warn()  { printf "%b%s%b\n" "$YELLOW" "$*" "$RESET"; }
error() { printf "%b%s%b\n" "$RED" "$*" "$RESET" >&2; }

pause_menu() {
    printf "\n按任意键返回菜单..."
    IFS= read -rsn1 _ || true
    printf "\n"
}

read_key() {
    local prompt="$1" key=""
    printf "%s" "$prompt"
    IFS= read -rsn1 key || true
    printf "%s\n" "$key"
    MENU_INPUT="$key"
}

# ---------- 管理器自动更新 ----------

download_self_update() {
    local destination="$1" cache_key
    cache_key="$(date +%s%N 2>/dev/null || date +%s)"

    if curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github.raw' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H 'Cache-Control: no-cache, no-store' \
        "${SELF_UPDATE_API}&cache=${cache_key}" -o "$destination" \
        && grep -q '^SCRIPT_BUILD=[0-9][0-9]*$' "$destination"; then
        return 0
    fi

    curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 \
        -H 'Cache-Control: no-cache, no-store' \
        "${SELF_UPDATE_URL}?cache=${cache_key}" -o "$destination"
}

check_self_update() {
    local force="${1:-0}" tmp remote_build remote_version

    if [[ "${ST_MANAGER_SKIP_UPDATE:-0}" == "1" && "$force" != "1" ]]; then
        UPDATE_STATUS="刚刚更新到 v${SCRIPT_VERSION}"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        UPDATE_STATUS="无法检查（缺少 curl）"
        return 0
    fi

    tmp="$(mktemp "${TMPDIR:-${PREFIX:-/tmp}/tmp}/st-manager.XXXXXX" 2>/dev/null)" || {
        UPDATE_STATUS="检查失败（无法创建临时文件）"
        return 0
    }

    if ! download_self_update "$tmp"; then
        rm -f "$tmp"
        UPDATE_STATUS="检查失败（网络错误）"
        return 0
    fi

    remote_build="$(sed -n 's/^SCRIPT_BUILD=\([0-9][0-9]*\)$/\1/p' "$tmp" | head -n 1)"
    remote_version="$(sed -n 's/^SCRIPT_VERSION="\([^"]*\)"$/\1/p' "$tmp" | head -n 1)"
    if [[ ! "$remote_build" =~ ^[0-9]+$ || -z "$remote_version" ]] \
        || [[ "$(head -n 1 "$tmp")" != '#!/usr/bin/env bash' ]] \
        || ! bash -n "$tmp"; then
        rm -f "$tmp"
        UPDATE_STATUS="检查失败（文件校验错误）"
        return 0
    fi

    if (( 10#$remote_build > 10#$SCRIPT_BUILD )); then
        mkdir -p "$BIN_DIR"
        cp "$tmp" "${MANAGER}.update" || { rm -f "$tmp"; return 0; }
        chmod 755 "${MANAGER}.update"
        mv -f "${MANAGER}.update" "$MANAGER"
        rm -f "$tmp"
        ok "管理器已从 v${SCRIPT_VERSION} 更新到 v${remote_version}，正在重启..."
        export ST_MANAGER_SKIP_UPDATE=1
        exec "$MANAGER" "${SELF_UPDATE_ARGS[@]}"
    fi

    rm -f "$tmp"
    if (( 10#$remote_build == 10#$SCRIPT_BUILD )); then
        UPDATE_STATUS="v${SCRIPT_VERSION}（已是最新）"
    else
        UPDATE_STATUS="本地 v${SCRIPT_VERSION}（不降级）"
    fi
}

install_manager() {
    local source_file
    source_file="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    mkdir -p "$BIN_DIR"
    if [[ "$source_file" != "$MANAGER" ]]; then
        cp "$source_file" "${MANAGER}.tmp" || return 1
        chmod 755 "${MANAGER}.tmp"
        mv -f "${MANAGER}.tmp" "$MANAGER"
    else
        chmod 755 "$MANAGER"
    fi
}

# ---------- Termux 软件包 ----------

is_termux() {
    [[ -n "${PREFIX:-}" && "$PREFIX" == *com.termux* ]] || command -v pkg >/dev/null 2>&1
}

package_available() {
    apt-cache show "$1" 2>/dev/null | grep -q '^Package:'
}

set_main_repo() {
    local repo_line="$1" sources="${PREFIX}/etc/apt/sources.list"
    mkdir -p "$(dirname "$sources")"
    printf '%s\n' "$repo_line" > "$sources"
    apt-get clean >/dev/null 2>&1 || true
    apt-get update -y
}

ensure_package_repo() {
    package_available git && package_available nodejs-lts && return 0

    warn "当前软件源缺少基础软件包，正在切换清华镜像..."
    set_main_repo 'deb https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main stable main' || true
    package_available git && package_available nodejs-lts && return 0

    warn "清华镜像不可用，正在切换 Termux 官方源..."
    set_main_repo 'deb https://packages.termux.dev/apt/termux-main stable main' || true
    package_available git && package_available nodejs-lts && return 0

    error "软件源不可用。请安装 F-Droid 或 GitHub Releases 提供的新版 Termux。"
    return 1
}

https_runtime_broken() {
    local helper="${PREFIX:-}/libexec/git-core/git-remote-https" output=""
    if ! command -v curl >/dev/null 2>&1 || ! curl --version >/dev/null 2>&1; then
        return 0
    fi
    if [[ -x "$helper" ]]; then
        output="$("$helper" 2>&1 || true)"
        grep -Eqi 'CANNOT LINK EXECUTABLE|cannot locate symbol|library .* not found' <<< "$output" && return 0
    fi
    return 1
}

repair_https_runtime() {
    warn "正在同步 Git、curl 和 OpenSSL 动态库..."
    apt-get update -y || return 1
    dpkg --configure -a || true
    DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y || return 1
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y \
        openssl libngtcp2 libnghttp3 libcurl curl git || return 1
    hash -r
    if https_runtime_broken; then
        error "HTTPS 动态库修复失败，请更新 Termux 后重试。"
        return 1
    fi
    ok "Git/curl/OpenSSL 已修复。"
}

install_dependencies() {
    local major
    if ! is_termux; then
        error "本脚本只能在 Termux 中运行。"
        return 1
    fi

    apt-get update -y || warn "软件源更新失败，正在尝试自动修复。"
    ensure_package_repo || return 1
    if https_runtime_broken; then
        repair_https_runtime || return 1
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        git nodejs-lts curl || return 1
    if package_available npm; then
        DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y npm || return 1
    fi
    if https_runtime_broken; then
        repair_https_runtime || return 1
    fi

    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if (( major != 24 )); then
        error "需要 Node.js 24.x，当前版本：$(node -v 2>/dev/null || echo 未安装)"
        return 1
    fi
    command -v npm >/dev/null 2>&1 || {
        error "npm 未安装，请执行 pkg install npm 后重试。"
        return 1
    }
}

# ---------- SillyTavern 固定版 ----------

has_sillytavern() {
    [[ -f "$ST_DIR/server.js" && -f "$ST_DIR/package.json" && -f "$ST_DIR/public/index.html" ]]
}

install_node_modules() {
    local install_options="--max-old-space-size=${ST_INSTALL_HEAP_MB:-512}" status
    info "正在安装 SillyTavern 运行依赖（低并发安装）..."
    (
        cd "$ST_DIR" || exit 1
        export NODE_ENV=production
        export npm_config_jobs="${npm_config_jobs:-1}"
        NODE_OPTIONS="$install_options" \
            npm install --no-save --no-audit --no-fund --no-progress \
                --loglevel=error --omit=dev
    )
    status=$?
    npm cache clean --force >/dev/null 2>&1 || true
    apt-get clean >/dev/null 2>&1 || true
    return "$status"
}

install_fixed_version() {
    install_dependencies || return 1

    if [[ -e "$ST_DIR" && ! -d "$ST_DIR" ]]; then
        error "$ST_DIR 已存在但不是目录。"
        return 1
    fi
    if [[ -d "$ST_DIR" && ! -d "$ST_DIR/.git" ]]; then
        error "$ST_DIR 已存在但不是 Git 安装，请先将该目录改名。"
        return 1
    fi

    if [[ ! -d "$ST_DIR/.git" ]]; then
        info "正在浅克隆固定版 SillyTavern ${ST_VERSION}..."
        git -c core.fileMode=false -c core.symlinks=false clone \
            --depth 1 --branch "$ST_VERSION" "$REPO" "$ST_DIR" || return 1
    else
        info "正在切换到固定版 SillyTavern ${ST_VERSION}..."
        if ! git -C "$ST_DIR" diff --quiet || ! git -C "$ST_DIR" diff --cached --quiet; then
            git -C "$ST_DIR" stash push -m "st-manager backup $(date '+%F %T')" || return 1
            warn "原有代码修改已保存在 git stash；用户数据没有删除。"
        fi
        git -C "$ST_DIR" fetch --depth 1 origin \
            "refs/tags/${ST_VERSION}:refs/tags/${ST_VERSION}" || return 1
        git -C "$ST_DIR" checkout --detach "$ST_VERSION" || return 1
    fi

    git -C "$ST_DIR" config core.fileMode false || true
    install_node_modules || return 1
    ok "SillyTavern ${ST_VERSION} 已安装，用户数据保持不变。"
}

start_sillytavern() {
    local effective_options="${NODE_OPTIONS:---max-old-space-size=${NODE_HEAP_MB}}"
    if ! has_sillytavern; then
        warn "未检测到 SillyTavern，将自动安装固定版 ${ST_VERSION}。"
        install_fixed_version || return
    fi
    if [[ ! -d "$ST_DIR/node_modules" ]]; then
        install_dependencies || return
        install_node_modules || return
    fi

    # 已经启动时不要重复创建服务，直接打开页面。
    if curl -fsS --max-time 1 'http://127.0.0.1:8000/' >/dev/null 2>&1; then
        termux-open-url 'http://127.0.0.1:8000' >/dev/null 2>&1 || true
        ok "SillyTavern 已在运行。"
        return
    fi

    info "正在以均衡模式启动：Node.js 内存上限 ${NODE_HEAP_MB} MB。"
    if command -v termux-open-url >/dev/null 2>&1; then
        (
            # 等服务器真正可访问后再打开，避免低配置手机启动较慢时出现空白页。
            for _ in $(seq 1 120); do
                if curl -fsS --max-time 1 'http://127.0.0.1:8000/' >/dev/null 2>&1; then
                    termux-open-url 'http://127.0.0.1:8000' >/dev/null 2>&1 || true
                    exit 0
                fi
                sleep 1
            done
        ) &
    fi
    (cd "$ST_DIR" && NODE_ENV=production NODE_OPTIONS="$effective_options" node server.js)
}

show_status() {
    local tag="" commit=""
    if has_sillytavern; then
        tag="$(git -C "$ST_DIR" describe --tags --exact-match 2>/dev/null || true)"
        commit="$(git -C "$ST_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    fi
    printf "安装目录：%s\n" "$ST_DIR"
    printf "酒馆版本：%s\n" "${tag:-未安装或非标签版本}"
    printf "Git 提交：%s\n" "${commit:-无}"
    printf "Node.js：%s\n" "$(node -v 2>/dev/null || echo 未安装)"
    printf "运行模式：均衡（Node.js 内存上限 %s MB）\n" "$NODE_HEAP_MB"
    printf "管理器：v%s（构建 %s）\n" "$SCRIPT_VERSION" "$SCRIPT_BUILD"
}

# ---------- 打开 Termux 自动显示菜单 ----------

remove_auto_block_from() {
    local file="$1" tmp
    [[ -f "$file" ]] || return 0
    tmp="${file}.st-manager.tmp"
    awk -v begin="$AUTO_BEGIN" -v end="$AUTO_END" '
        $0 == begin { skip=1; next }
        $0 == end   { skip=0; next }
        !skip       { print }
    ' "$file" > "$tmp" && mv -f "$tmp" "$file"
}

append_auto_block() {
    local file="$1"
    remove_auto_block_from "$file"
    cat >> "$file" <<'EOF'
# >>> SillyTavern Termux Manager >>>
if [[ $- == *i* && -x "$HOME/.local/bin/st-manager" && -z "${ST_MANAGER_ACTIVE:-}" ]]; then
    ST_MANAGER_ACTIVE=1 "$HOME/.local/bin/st-manager" --menu
fi
# <<< SillyTavern Termux Manager <<<
EOF
}

ensure_bash_profile() {
    touch "$BASH_PROFILE"
    if ! grep -Fq ". \"\$HOME/.bashrc\"" "$BASH_PROFILE"; then
        cat >> "$BASH_PROFILE" <<'EOF'

[[ -f "$HOME/.bashrc" ]] && . "$HOME/.bashrc"
EOF
    fi
}

enable_auto_menu() {
    touch "$BASHRC" "$ZSHRC"
    append_auto_block "$BASHRC"
    append_auto_block "$ZSHRC"
    ensure_bash_profile
    ok "已开启：打开 Termux 自动显示管理菜单。"
}

disable_auto_menu() {
    remove_auto_block_from "$BASHRC"
    remove_auto_block_from "$ZSHRC"
    ok "已关闭 Termux 自动菜单。"
}

auto_menu_enabled() {
    grep -Fq "$AUTO_BEGIN" "$BASHRC" 2>/dev/null || grep -Fq "$AUTO_BEGIN" "$ZSHRC" 2>/dev/null
}

toggle_auto_menu() {
    if auto_menu_enabled; then disable_auto_menu; else enable_auto_menu; fi
}

manual_self_update() {
    UPDATE_STATUS="正在检查..."
    SELF_UPDATE_ARGS=()
    check_self_update 1
    ok "$UPDATE_STATUS"
}

# ---------- 菜单 ----------

main_menu() {
    while true; do
        clear 2>/dev/null || true
        printf "%b========================================\n" "$CYAN"
        printf "  SillyTavern %s Termux 管理器\n" "$ST_VERSION"
        printf "  管理器 v%s\n" "$SCRIPT_VERSION"
        printf "========================================%b\n" "$RESET"
        printf "脚本更新：%s\n" "$UPDATE_STATUS"
        printf "酒馆状态：%s\n\n" "$(has_sillytavern && echo 已安装 || echo 未安装)"
        printf "  1) 启动 SillyTavern\n"
        printf "  2) 安装 / 修复固定版 %s\n" "$ST_VERSION"
        printf "  3) 查看状态\n"
        if auto_menu_enabled; then
            printf "  4) 关闭自动菜单 [当前：开]\n"
        else
            printf "  4) 开启自动菜单 [当前：关]\n"
        fi
        printf "  5) 检查管理器更新\n"
        printf "  0) 退出到命令行\n\n"
        read_key "请选择 [0-5]（自动确认）："
        case "$MENU_INPUT" in
            1) start_sillytavern; pause_menu ;;
            2) install_fixed_version; pause_menu ;;
            3) show_status; pause_menu ;;
            4) toggle_auto_menu; pause_menu ;;
            5) manual_self_update; pause_menu ;;
            0) break ;;
            *) warn "请输入 0 到 5。"; sleep 1 ;;
        esac
    done
}

main() {
    SELF_UPDATE_ARGS=("$@")
    check_self_update 0
    install_manager || {
        error "管理器安装失败。"
        exit 1
    }

    mkdir -p "$STATE_DIR"
    if [[ ! -f "$INITIALIZED" ]]; then
        enable_auto_menu
        touch "$INITIALIZED"
    fi

    case "${1:-}" in
        --start) start_sillytavern ;;
        --status) show_status ;;
        --no-auto) disable_auto_menu ;;
        --menu|'') main_menu ;;
        *) main_menu ;;
    esac
}

main "$@"
