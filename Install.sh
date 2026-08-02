#!/usr/bin/env bash

# SillyTavern Termux 一键安装与管理脚本
# 上游项目：https://github.com/SillyTavern/SillyTavern

set -u

REPO="https://github.com/SillyTavern/SillyTavern.git"
ST_DIR="${HOME}/SillyTavern"
BIN_DIR="${HOME}/.local/bin"
MANAGER="${BIN_DIR}/st-manager"
BASHRC="${HOME}/.bashrc"
BASH_PROFILE="${HOME}/.bash_profile"
ZSHRC="${HOME}/.zshrc"
STATE_DIR="${HOME}/.config/st-manager"
INITIALIZED="${STATE_DIR}/initialized"
AUTO_BEGIN="# >>> SillyTavern Termux Manager >>>"
AUTO_END="# <<< SillyTavern Termux Manager <<<"
RUN_FROM_INSTALLER=0

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
    printf "\n按回车键返回菜单..."
    read -r _ || true
}

is_termux() {
    [[ -n "${PREFIX:-}" && "$PREFIX" == *com.termux* ]] || command -v pkg >/dev/null 2>&1
}

install_manager() {
    mkdir -p "$BIN_DIR"
    local source_file
    source_file="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
    if [[ "$source_file" != "$MANAGER" ]]; then
        RUN_FROM_INSTALLER=1
        cp "$source_file" "${MANAGER}.tmp" || return 1
        chmod 755 "${MANAGER}.tmp"
        mv -f "${MANAGER}.tmp" "$MANAGER"
    else
        chmod 755 "$MANAGER"
    fi
}

remove_auto_block_from() {
    local rc_file="$1"
    [[ -f "$rc_file" ]] || return 0
    local tmp="${rc_file}.st-manager.tmp"
    awk -v begin="$AUTO_BEGIN" -v end="$AUTO_END" '
        $0 == begin { skipping=1; next }
        $0 == end   { skipping=0; next }
        !skipping   { print }
    ' "$rc_file" > "$tmp" && mv -f "$tmp" "$rc_file"
}

remove_auto_block() {
    remove_auto_block_from "$BASHRC"
    remove_auto_block_from "$ZSHRC"
}

append_auto_block() {
    local rc_file="$1"
    touch "$rc_file"
    remove_auto_block_from "$rc_file"
    cat >> "$rc_file" <<'EOF'

# >>> SillyTavern Termux Manager >>>
if [[ $- == *i* ]] && [[ -t 0 ]] && [[ -x "$HOME/.local/bin/st-manager" ]] && [[ -z "${ST_MANAGER_ACTIVE:-}" ]]; then
    ST_MANAGER_ACTIVE=1 "$HOME/.local/bin/st-manager"
fi
# <<< SillyTavern Termux Manager <<<
EOF
}

enable_auto_menu() {
    append_auto_block "$BASHRC"
    append_auto_block "$ZSHRC"

    # Termux 可能以 login shell 启动；确保它会读取 ~/.bashrc。
    ensure_bash_profile_loader
    ok "已设置：以后打开 Termux 会自动进入管理菜单。"
}

disable_auto_menu() {
    remove_auto_block
    ok "已关闭 Termux 启动时自动进入菜单。"
    info "仍可输入 st-manager 手动打开菜单。"
}

auto_menu_enabled() {
    { [[ -f "$BASHRC" ]] && grep -Fq "$AUTO_BEGIN" "$BASHRC"; } ||
    { [[ -f "$ZSHRC" ]] && grep -Fq "$AUTO_BEGIN" "$ZSHRC"; }
}

ensure_bash_profile_loader() {
    touch "$BASH_PROFILE"
    if ! grep -Fq '# SillyTavern: load .bashrc' "$BASH_PROFILE"; then
        cat >> "$BASH_PROFILE" <<'EOF'

# SillyTavern: load .bashrc
if [[ -f "$HOME/.bashrc" ]]; then
    . "$HOME/.bashrc"
fi
EOF
    fi
}

install_dependencies() {
    if ! is_termux; then
        error "本脚本只能在 Termux 中安装。"
        return 1
    fi

    info "正在更新软件源并安装依赖：git、Node.js 24 LTS、npm、nano、curl..."
    pkg update -y || return 1
    # Termux 的 nodejs-lts 当前为 Node.js 24；显式安装 npm，避免新版
    # nodejs-lts 不再内置 npm 时 SillyTavern 无法安装依赖。
    pkg install -y git nodejs-lts npm nano curl || return 1

    if [[ "$(getconf LONG_BIT 2>/dev/null || echo 64)" == "32" ]]; then
        warn "检测到 32 位 Android，额外安装 esbuild。"
        pkg install -y esbuild || return 1
    fi

    local major
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if (( major != 24 )); then
        error "此安装器默认要求 Node.js 24.x，当前版本：$(node -v 2>/dev/null || echo 未安装)"
        error "请确认使用最新版 Termux 软件源后重试。"
        return 1
    fi
    if ! command -v npm >/dev/null 2>&1; then
        error "npm 安装失败，请执行 pkg install npm 后重试。"
        return 1
    fi
    ok "依赖安装完成，Node.js $(node -v)，npm $(npm -v)。"
}

install_node_modules() {
    info "正在安装 SillyTavern Node.js 依赖..."
    (
        cd "$ST_DIR" || exit 1
        export NODE_ENV=production
        npm install --no-save --no-audit --no-fund --loglevel=error --no-progress --omit=dev --ignore-scripts
    )
}

valid_repo() {
    [[ -d "$ST_DIR/.git" ]]
}

stash_changes() {
    STASHED=0
    if [[ -n "$(git -C "$ST_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
        warn "检测到程序代码有本地修改，切换前将自动暂存。"
        if git -C "$ST_DIR" stash push -m "st-manager auto-stash $(date '+%F %T')"; then
            STASHED=1
        else
            error "暂存本地修改失败，已取消切换。"
            return 1
        fi
    fi
}

restore_changes() {
    if [[ "${STASHED:-0}" == "1" ]]; then
        warn "正在恢复切换前的本地修改..."
        git -C "$ST_DIR" stash pop || warn "自动恢复发生冲突；修改仍在 git stash 中，请手动处理。"
    fi
}

install_or_switch() {
    local kind="$1" ref="$2"

    install_dependencies || return 1

    if [[ -e "$ST_DIR" && ! -d "$ST_DIR/.git" ]]; then
        error "$ST_DIR 已存在，但不是 Git 仓库。请先将该目录改名后重试。"
        return 1
    fi

    if ! valid_repo; then
        info "正在从官方仓库安装版本：$ref"
        git clone --depth 1 --branch "$ref" "$REPO" "$ST_DIR" || return 1
    else
        info "正在将已有安装切换到：$ref"
        stash_changes || return 1

        if [[ "$kind" == "branch" ]]; then
            git -C "$ST_DIR" fetch --depth=1 origin "$ref:refs/remotes/origin/$ref" || {
                restore_changes; return 1;
            }
            if git -C "$ST_DIR" show-ref --verify --quiet "refs/heads/$ref"; then
                git -C "$ST_DIR" checkout "$ref" || { restore_changes; return 1; }
            else
                git -C "$ST_DIR" checkout -b "$ref" --track "origin/$ref" || { restore_changes; return 1; }
            fi
            git -C "$ST_DIR" pull --rebase --autostash origin "$ref" || {
                restore_changes; return 1;
            }
        else
            git -C "$ST_DIR" fetch --depth=1 origin "refs/tags/$ref:refs/tags/$ref" || {
                restore_changes; return 1;
            }
            git -C "$ST_DIR" checkout --detach "$ref" || { restore_changes; return 1; }
        fi

        restore_changes
    fi

    install_node_modules || return 1
    ok "SillyTavern $ref 安装完成。"
}

list_release_tags() {
    git ls-remote --tags --refs "$REPO" 2>/dev/null \
        | awk -F/ '{print $3}' \
        | grep -E '^[vV]?[0-9]+([.][0-9]+){2}$' \
        | awk -F. '{ major=$1; sub(/^[vV]/, "", major); if (major > 1 || (major == 1 && $2 >= 11)) print }' \
        | sort -Vr
}

choose_tag() {
    info "正在读取官方版本列表..."
    local tags=() choice tag i
    mapfile -t tags < <(list_release_tags)

    if (( ${#tags[@]} == 0 )); then
        error "未能读取版本列表，请检查网络。"
        return 1
    fi

    printf "\n所有 1.11.0 及以上正式版本：\n"
    for i in "${!tags[@]}"; do
        printf "  %2d) %s\n" "$((i + 1))" "${tags[$i]}"
    done
    printf "   0) 返回\n\n"
    read -r -p "输入序号或完整版本号：" choice
    [[ "$choice" == "0" ]] && return 2

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( 10#$choice >= 1 && 10#$choice <= ${#tags[@]} )); then
        tag="${tags[$((10#$choice - 1))]}"
    else
        tag="$choice"
    fi

    local found=0 released_tag
    for released_tag in "${tags[@]}"; do
        if [[ "$released_tag" == "$tag" ]]; then
            found=1
            break
        fi
    done
    if (( found == 0 )); then
        error "请选择列表中的 1.11.0 或更高正式版本：$tag"
        return 1
    fi
    install_or_switch tag "$tag"
}

choose_version() {
    while true; do
        printf "\n%b选择要安装或切换的版本%b\n" "$CYAN" "$RESET"
        printf "  1) release  稳定版（推荐，可持续更新）\n"
        printf "  2) staging  测试版（更新快，可能不稳定）\n"
        printf "  3) 选择正式版本（1.11.0 及以上可随意切换）\n"
        printf "  0) 返回\n\n"
        read -r -p "请选择 [0-3]：" choice
        case "$choice" in
            1) install_or_switch branch release; return $? ;;
            2) install_or_switch branch staging; return $? ;;
            3) choose_tag; case $? in 0) return 0;; 2) continue;; *) return 1;; esac ;;
            0) return 2 ;;
            *) warn "请输入 0、1、2 或 3。" ;;
        esac
    done
}

start_sillytavern() {
    if ! valid_repo; then
        warn "尚未安装 SillyTavern，请先选择版本。"
        choose_version || return
    fi

    info "即将启动 SillyTavern；停止服务请按 Ctrl+C。"
    if command -v termux-open-url >/dev/null 2>&1; then
        ( sleep 6; termux-open-url "http://127.0.0.1:8000" >/dev/null 2>&1 || true ) &
    fi
    (cd "$ST_DIR" && bash start.sh)
}

update_sillytavern() {
    if ! valid_repo; then
        error "尚未安装 SillyTavern。"
        return 1
    fi

    local branch
    branch="$(git -C "$ST_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ -z "$branch" ]]; then
        warn "当前是锁定的正式版本，不能直接更新。请使用菜单 2 切换到新版本或 release。"
        return 1
    fi

    info "正在更新 $branch..."
    git -C "$ST_DIR" pull --rebase --autostash origin "$branch" || return 1
    install_node_modules || return 1
    ok "更新完成。"
}

show_version() {
    if ! valid_repo; then
        warn "尚未安装 SillyTavern。"
        return
    fi
    local branch tag commit
    branch="$(git -C "$ST_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    tag="$(git -C "$ST_DIR" describe --tags --exact-match 2>/dev/null || true)"
    commit="$(git -C "$ST_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    printf "安装目录：%s\n" "$ST_DIR"
    printf "当前版本：%s\n" "${tag:-${branch:-未知}}"
    printf "Git 提交：%s\n" "$commit"
    printf "Node.js：%s\n" "$(node -v 2>/dev/null || echo 未安装)"
}

toggle_auto_menu() {
    if auto_menu_enabled; then
        disable_auto_menu
    else
        enable_auto_menu
    fi
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        printf "%b" "$CYAN"
        printf "========================================\n"
        printf "       SillyTavern Termux 管理器         \n"
        printf "========================================\n"
        printf "%b" "$RESET"
        printf "  1) 启动 SillyTavern\n"
        printf "  2) 安装 / 切换版本\n"
        printf "  3) 更新当前版本\n"
        printf "  4) 查看当前版本\n"
        if auto_menu_enabled; then
            printf "  5) 关闭 Termux 自动菜单 [当前：开]\n"
        else
            printf "  5) 开启 Termux 自动菜单 [当前：关]\n"
        fi
        printf "  0) 退出到 Termux 命令行\n\n"
        read -r -p "请选择 [0-5]：" choice
        case "$choice" in
            1) start_sillytavern; pause_menu ;;
            2) choose_version; pause_menu ;;
            3) update_sillytavern; pause_menu ;;
            4) show_version; pause_menu ;;
            5) toggle_auto_menu; pause_menu ;;
            0) break ;;
            *) warn "请输入 0 到 5。"; sleep 1 ;;
        esac
    done
}

main() {
    if ! is_termux; then
        error "请在 Android Termux 中运行此脚本。"
        exit 1
    fi

    install_manager || {
        error "管理脚本安装失败。"
        exit 1
    }
    export PATH="$BIN_DIR:$PATH"

    # 重新执行下载的 Install.sh 时也会主动修复自动菜单；从已安装的
    # st-manager 启动时仍尊重用户在菜单中的开关设置。
    if [[ "$RUN_FROM_INSTALLER" == "1" || ! -f "$INITIALIZED" ]]; then
        enable_auto_menu
        mkdir -p "$STATE_DIR"
        touch "$INITIALIZED"
    elif auto_menu_enabled; then
        # 修复旧版已初始化、但尚未配置 login shell 的安装。
        ensure_bash_profile_loader
    fi

    case "${1:-}" in
        --start) start_sillytavern ;;
        --version) show_version ;;
        --no-auto) disable_auto_menu ;;
        *) main_menu ;;
    esac
}

main "$@"
