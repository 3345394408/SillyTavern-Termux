#!/usr/bin/env bash

# SillyTavern Termux 一键安装与管理脚本
# 上游项目：https://github.com/SillyTavern/SillyTavern

set -u

SCRIPT_VERSION="1.4.2"
SCRIPT_BUILD=2026080310
REPO="https://github.com/SillyTavern/SillyTavern.git"
SELF_UPDATE_URL="https://raw.githubusercontent.com/3345394408/SillyTavern-Termux/main/Install.sh"
EXTERNAL_STORAGE_ROOT="/storage/BA73-022B"
EXTERNAL_ST_DIR="${EXTERNAL_STORAGE_ROOT}/SillyTavern"
DEFAULT_ST_DIR="${HOME}/SillyTavern"
ST_DIR="$DEFAULT_ST_DIR"
BIN_DIR="${HOME}/.local/bin"
MANAGER="${BIN_DIR}/st-manager"
BASHRC="${HOME}/.bashrc"
BASH_PROFILE="${HOME}/.bash_profile"
ZSHRC="${HOME}/.zshrc"
STATE_DIR="${HOME}/.config/st-manager"
INITIALIZED="${STATE_DIR}/initialized"
INSTALL_DIR_FILE="${STATE_DIR}/install-dir"
AUTO_BEGIN="# >>> SillyTavern Termux Manager >>>"
AUTO_END="# <<< SillyTavern Termux Manager <<<"
RUN_FROM_INSTALLER=0
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

read_menu_key() {
    local prompt="$1" key=""
    printf "%s" "$prompt"
    IFS= read -rsn1 key || true
    printf "%s\n" "$key"
    MENU_INPUT="$key"
}

read_timed_choice() {
    local prompt="$1" key="" value=""
    printf "%s" "$prompt"
    IFS= read -rsn1 key || true
    value="$key"
    printf "%s" "$key"

    # 等待很短时间接收两位序号或完整版本号，不需要按回车确认。
    while IFS= read -rsn1 -t 0.6 key; do
        [[ "$key" == $'\n' || "$key" == $'\r' ]] && break
        [[ "$key" =~ ^[0-9vV.]$ ]] || break
        value+="$key"
        printf "%s" "$key"
    done
    printf "\n"
    MENU_INPUT="$value"
}

is_termux() {
    [[ -n "${PREFIX:-}" && "$PREFIX" == *com.termux* ]] || command -v pkg >/dev/null 2>&1
}

termux_package_available() {
    apt-cache show "$1" 2>/dev/null | grep -q '^Package:'
}

set_termux_main_repo() {
    local repo_line="$1"
    local sources="$PREFIX/etc/apt/sources.list"
    mkdir -p "$(dirname "$sources")"
    if [[ -f "$sources" && ! -f "${sources}.st-manager.bak" ]]; then
        cp "$sources" "${sources}.st-manager.bak" || true
    fi
    printf '%s\n' "$repo_line" > "$sources"
    apt-get clean >/dev/null 2>&1 || true
    apt-get update -y
}

repair_termux_repo() {
    termux_package_available git && termux_package_available nodejs-lts && return 0

    warn "当前 Termux 软件源缺少基础软件包，正在自动修复软件源..."

    # 中国大陆优先使用 Termux 官方镜像列表中的清华 TUNA 镜像。
    set_termux_main_repo \
        'deb https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main stable main' || true
    termux_package_available git && termux_package_available nodejs-lts && return 0

    warn "清华镜像不可用，正在尝试 Termux 官方源..."
    set_termux_main_repo \
        'deb https://packages.termux.dev/apt/termux-main stable main' || true
    termux_package_available git && termux_package_available nodejs-lts && return 0

    error "软件源修复失败。你可能使用了已停止维护的 Google Play 版 Termux。"
    error "请改用 F-Droid 或 Termux GitHub Releases 提供的新版 Termux。"
    return 1
}

repair_termux_runtime() {
    if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
        return 0
    fi

    warn "检测到 Termux 软件包版本混用，curl/SSL 无法启动，正在完整升级修复..."
    apt-get update -y || {
        set_termux_main_repo \
            'deb https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main stable main' || return 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y curl openssl libngtcp2 \
        || DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl \
        || return 1

    if ! curl --version >/dev/null 2>&1; then
        error "curl/SSL 修复失败。请更换新版 Termux 后重试。"
        return 1
    fi
    ok "Termux 软件包和 curl/SSL 已修复。"
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

check_self_update() {
    local force="${1:-0}"
    if [[ "${ST_MANAGER_SKIP_UPDATE:-0}" == "1" && "$force" != "1" ]]; then
        UPDATE_STATUS="刚刚自动更新到 v${SCRIPT_VERSION}"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        UPDATE_STATUS="无法检查（缺少 curl）"
        return 0
    fi

    local tmp remote_build source_file
    tmp="$(mktemp "${TMPDIR:-${PREFIX:-/tmp}/tmp}/st-manager-update.XXXXXX" 2>/dev/null)" || {
        UPDATE_STATUS="检查失败（无法创建临时文件）"
        return 0
    }

    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 30 \
        -H 'Cache-Control: no-cache' \
        "${SELF_UPDATE_URL}?v=$(date +%s)" -o "$tmp"; then
        rm -f "$tmp"
        UPDATE_STATUS="检查失败（网络错误）"
        return 0
    fi

    remote_build="$(sed -n 's/^SCRIPT_BUILD=\([0-9][0-9]*\)$/\1/p' "$tmp" | head -n 1)"
    source_file="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

    if [[ ! "$remote_build" =~ ^[0-9]+$ ]] \
        || [[ "$(head -n 1 "$tmp")" != '#!/usr/bin/env bash' ]] \
        || ! bash -n "$tmp"; then
        rm -f "$tmp"
        warn "管理器在线更新文件校验失败，继续使用当前版本。"
        UPDATE_STATUS="检查失败（文件校验错误）"
        return 0
    fi

    # 只升级不降级；构建号相同时也比较内容，避免遗漏小修复。
    if (( 10#$remote_build > 10#$SCRIPT_BUILD )) \
        || { (( 10#$remote_build == 10#$SCRIPT_BUILD )) && ! cmp -s "$tmp" "$source_file"; }; then
        mkdir -p "$BIN_DIR"
        cp "$tmp" "${MANAGER}.update" || { rm -f "$tmp"; return 0; }
        chmod 755 "${MANAGER}.update"
        mv -f "${MANAGER}.update" "$MANAGER"
        rm -f "$tmp"
        ok "管理器已自动更新，正在重新启动..."
        export ST_MANAGER_SKIP_UPDATE=1
        exec "$MANAGER" "${SELF_UPDATE_ARGS[@]}"
    fi

    rm -f "$tmp"
    if (( 10#$remote_build < 10#$SCRIPT_BUILD )); then
        UPDATE_STATUS="本地版本较新 v${SCRIPT_VERSION}"
    else
        UPDATE_STATUS="已是最新 v${SCRIPT_VERSION}"
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
    apt-get update -y || warn "原软件源更新失败，将尝试自动修复。"
    repair_termux_repo || return 1
    repair_termux_runtime || return 1

    DEBIAN_FRONTEND=noninteractive apt-get install -y git nodejs-lts nano curl || return 1
    # 新版 nodejs-lts 将 npm 拆分为独立软件包；旧版可能仍内置 npm。
    if termux_package_available npm; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y npm || return 1
    fi

    if [[ "$(getconf LONG_BIT 2>/dev/null || echo 64)" == "32" ]]; then
        warn "检测到 32 位 Android，额外安装 esbuild。"
        DEBIAN_FRONTEND=noninteractive apt-get install -y esbuild || return 1
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
        local npm_args=(
            --no-save --no-audit --no-fund --loglevel=error --no-progress
            --omit=dev --ignore-scripts
        )
        # 仅当识别到既有外置存储安装时禁用 bin 链接；默认 Termux HOME 安装保持标准行为。
        if [[ "$ST_DIR" == "$EXTERNAL_STORAGE_ROOT"* ]]; then
            npm_args+=(--no-bin-links)
        fi
        npm install "${npm_args[@]}"
    )
}

has_sillytavern_files() {
    [[ -f "$ST_DIR/server.js" \
        && -f "$ST_DIR/package.json" \
        && -f "$ST_DIR/public/index.html" ]]
}

valid_repo() {
    has_sillytavern_files || return 1
    command -v git >/dev/null 2>&1 || return 1
    if ! git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$ST_DIR"; then
        git config --global --add safe.directory "$ST_DIR" >/dev/null 2>&1 || true
    fi
    git -C "$ST_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

remember_install_dir() {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$ST_DIR" > "$INSTALL_DIR_FILE"
}

prepare_install_storage() {
    [[ "$ST_DIR" == "$EXTERNAL_STORAGE_ROOT"* ]] || return 0

    if [[ ! -d "$EXTERNAL_STORAGE_ROOT" ]]; then
        error "没有检测到外置存储卡：$EXTERNAL_STORAGE_ROOT"
        error "请确认存储卡已挂载，卷标路径没有变化。"
        return 1
    fi

    if [[ ! -w "$EXTERNAL_STORAGE_ROOT" ]]; then
        warn "Termux 尚未取得外置存储权限，正在请求权限..."
        if command -v termux-setup-storage >/dev/null 2>&1; then
            termux-setup-storage || true
        fi
        sleep 2
    fi

    if [[ ! -w "$EXTERNAL_STORAGE_ROOT" ]]; then
        error "无法写入 $EXTERNAL_STORAGE_ROOT"
        error "请在 Android 设置中允许 Termux 访问文件/所有文件，然后重新运行。"
        return 1
    fi
}

detect_install_dir() {
    local saved="" candidate="" found="" search_root=""

    if [[ -f "$INSTALL_DIR_FILE" ]]; then
        IFS= read -r saved < "$INSTALL_DIR_FILE" || true
        if [[ -n "$saved" ]]; then
            candidate="$ST_DIR"
            ST_DIR="$saved"
            if has_sillytavern_files; then
                return 0
            fi
            ST_DIR="$candidate"
        fi
    fi

    for candidate in \
        "$ST_DIR" \
        "$EXTERNAL_ST_DIR" \
        "$EXTERNAL_STORAGE_ROOT" \
        "$EXTERNAL_STORAGE_ROOT/sillytavern" \
        "$HOME/SillyTavern" \
        "$HOME/sillytavern"; do
        ST_DIR="$candidate"
        if has_sillytavern_files; then
            remember_install_dir
            return 0
        fi
    done

    # 兼容旧脚本创建的任意目录名，并递归扫描指定外置存储卡。
    for search_root in "$HOME" "$EXTERNAL_STORAGE_ROOT"; do
        [[ -d "$search_root" ]] || continue
        found="$(
            find "$search_root" -maxdepth 7 \
                -type d -name node_modules -prune -o \
                -type f -name server.js -print 2>/dev/null \
                | while IFS= read -r candidate; do
                    candidate="${candidate%/server.js}"
                    if [[ -f "$candidate/package.json" && -f "$candidate/public/index.html" ]]; then
                        printf '%s\n' "$candidate"
                        break
                    fi
                done
        )"
        if [[ -n "$found" ]]; then
            ST_DIR="$found"
            remember_install_dir
            ok "已自动识别 SillyTavern：$ST_DIR"
            return 0
        fi
    done

    ST_DIR="$DEFAULT_ST_DIR"
    return 1
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
    detect_install_dir || true
    prepare_install_storage || return 1

    if [[ -e "$ST_DIR" ]] && ! valid_repo; then
        error "$ST_DIR 已存在，但不是 Git 仓库。请先将该目录改名后重试。"
        return 1
    fi

    if ! valid_repo; then
        info "正在从官方仓库安装版本：$ref"
        git -c core.fileMode=false -c core.symlinks=false \
            clone --depth 1 --branch "$ref" "$REPO" "$ST_DIR" || return 1
        git -C "$ST_DIR" config core.fileMode false || true
        git -C "$ST_DIR" config core.symlinks false || true
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
    remember_install_dir
    ok "SillyTavern $ref 安装完成。"
}

filter_supported_tags() {
    grep -E '^[vV]?[0-9]+([.][0-9]+){2}$' \
        | awk -F. '{ major=$1; sub(/^[vV]/, "", major); if (major > 1 || (major == 1 && $2 >= 11)) print }' \
        | sort -Vr \
        | awk '!seen[$0]++'
}

list_release_tags() {
    local tags=""

    # 首次运行时可能还没安装 git，因此优先使用安装指令已有的 curl。
    if command -v curl >/dev/null 2>&1; then
        tags="$(
            curl -fsSL --retry 2 --connect-timeout 15 --max-time 30 \
                -H 'Accept: application/vnd.github+json' \
                -H 'User-Agent: SillyTavern-Termux-Manager' \
                'https://api.github.com/repos/SillyTavern/SillyTavern/tags?per_page=100' 2>/dev/null \
                | awk -F'"' '/"name"[[:space:]]*:/ {print $4}' \
                | filter_supported_tags
        )"
    fi

    # GitHub API 不通时再尝试 Git，并强制 HTTP/1.1 提高 Termux 网络兼容性。
    if [[ -z "$tags" ]] && command -v git >/dev/null 2>&1; then
        tags="$(
            git -c http.version=HTTP/1.1 ls-remote --tags --refs "$REPO" 2>/dev/null \
                | awk -F/ '{print $3}' \
                | filter_supported_tags
        )"
    fi

    # 固定保留用户指定的 1.11.4，即使版本接口暂时只返回部分标签也能选择。
    tags="$(printf '%s\n%s\n' "$tags" '1.11.4' | filter_supported_tags)"

    if [[ -n "$tags" ]]; then
        printf '%s\n' "$tags"
    fi
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
    read_timed_choice "输入序号或完整版本号（自动确认）："
    choice="$MENU_INPUT"
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
        printf "  4) 固定版本 1.11.4\n"
        printf "  0) 返回\n\n"
        read_menu_key "请选择 [0-4]（自动确认）："
        choice="$MENU_INPUT"
        case "$choice" in
            1) install_or_switch branch release; return $? ;;
            2) install_or_switch branch staging; return $? ;;
            3) choose_tag; case $? in 0) return 0;; 2) continue;; *) return 1;; esac ;;
            4) install_or_switch tag 1.11.4; return $? ;;
            0) return 2 ;;
            *) warn "请输入 0、1、2、3 或 4。" ;;
        esac
    done
}

start_sillytavern() {
    detect_install_dir || true
    if ! has_sillytavern_files; then
        warn "尚未安装 SillyTavern，请先选择版本。"
        choose_version || return
        detect_install_dir || true
    fi

    if [[ ! -d "$ST_DIR/node_modules" ]]; then
        warn "检测到程序文件，但缺少 Node.js 依赖，正在补充安装。"
        install_dependencies || return
        install_node_modules || return
    fi

    info "即将启动 SillyTavern；停止服务请按 Ctrl+C。"
    if command -v termux-open-url >/dev/null 2>&1; then
        ( sleep 6; termux-open-url "http://127.0.0.1:8000" >/dev/null 2>&1 || true ) &
    fi
    if [[ "$ST_DIR" == "$EXTERNAL_STORAGE_ROOT"* ]]; then
        # 外置存储通常不支持可执行权限，因此直接由 Termux 内部的 Node.js 启动。
        (cd "$ST_DIR" && node server.js)
    else
        (cd "$ST_DIR" && bash start.sh)
    fi
}

update_sillytavern() {
    detect_install_dir || true
    if ! valid_repo; then
        if has_sillytavern_files; then
            error "已找到 SillyTavern，但它不是 Git 安装，无法自动更新代码。"
            info "安装目录：$ST_DIR"
        else
            error "尚未安装 SillyTavern。"
        fi
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
    detect_install_dir || true
    if ! has_sillytavern_files; then
        warn "尚未安装 SillyTavern。"
        return
    fi
    local branch tag commit
    branch="$(git -C "$ST_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    tag="$(git -C "$ST_DIR" describe --tags --exact-match 2>/dev/null || true)"
    commit="$(git -C "$ST_DIR" rev-parse --short HEAD 2>/dev/null || true)"
    printf "安装目录：%s\n" "$ST_DIR"
    printf "管理器版本：%s（构建 %s）\n" "$SCRIPT_VERSION" "$SCRIPT_BUILD"
    printf "当前版本：%s\n" "${tag:-${branch:-手动安装}}"
    printf "Git 提交：%s\n" "${commit:-无}"
    printf "Node.js：%s\n" "$(node -v 2>/dev/null || echo 未安装)"
}

toggle_auto_menu() {
    if auto_menu_enabled; then
        disable_auto_menu
    else
        enable_auto_menu
    fi
}

manual_self_update() {
    UPDATE_STATUS="正在检查..."
    SELF_UPDATE_ARGS=()
    check_self_update 1
    ok "$UPDATE_STATUS"
}

main_menu() {
    while true; do
        clear 2>/dev/null || true
        printf "%b" "$CYAN"
        printf "========================================\n"
        printf "       SillyTavern Termux 管理器         \n"
        printf "               v%s\n" "$SCRIPT_VERSION"
        printf "========================================\n"
        printf "%b" "$RESET"
        printf "  脚本更新：%s\n" "$UPDATE_STATUS"
        if has_sillytavern_files; then
            printf "  酒馆目录：%s\n\n" "$ST_DIR"
        else
            printf "  酒馆目录：未检测到\n\n"
        fi
        printf "  1) 启动 SillyTavern\n"
        printf "  2) 安装 / 切换版本\n"
        printf "  3) 更新当前版本\n"
        printf "  4) 查看当前版本\n"
        if auto_menu_enabled; then
            printf "  5) 关闭 Termux 自动菜单 [当前：开]\n"
        else
            printf "  5) 开启 Termux 自动菜单 [当前：关]\n"
        fi
        printf "  6) 立即检查管理器更新\n"
        printf "  0) 退出到 Termux 命令行\n\n"
        read_menu_key "请选择 [0-6]（自动确认）："
        choice="$MENU_INPUT"
        case "$choice" in
            1) start_sillytavern; pause_menu ;;
            2) choose_version; pause_menu ;;
            3) update_sillytavern; pause_menu ;;
            4) show_version; pause_menu ;;
            5) toggle_auto_menu; pause_menu ;;
            6) manual_self_update; pause_menu ;;
            0) break ;;
            *) warn "请输入 0 到 6。"; sleep 1 ;;
        esac
    done
}

main() {
    if ! is_termux; then
        error "请在 Android Termux 中运行此脚本。"
        exit 1
    fi

    # 每次打开管理器时自动检查 GitHub 上的新版本。
    SELF_UPDATE_ARGS=("$@")
    check_self_update 0

    install_manager || {
        error "管理脚本安装失败。"
        exit 1
    }
    export PATH="$BIN_DIR:$PATH"
    detect_install_dir || true

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
