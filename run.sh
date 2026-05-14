#!/usr/bin/env bash
# QwenPaw 部署管理脚本
# 功能：环境检测/安装、启动、停止、PM2管理、日志查看
set -uo pipefail

# ── 颜色 ──────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD="\033[1m" GREEN="\033[0;32m" YELLOW="\033[0;33m"
    RED="\033[0;31m" CYAN="\033[0;36m" RESET="\033[0m"
else
    BOLD="" GREEN="" YELLOW="" RED="" CYAN="" RESET=""
fi

info()  { printf "${GREEN}[QwenPaw]${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}[QwenPaw]${RESET} %s\n" "$*"; }
error() { printf "${RED}[QwenPaw]${RESET} %s\n" "$*" >&2; }

# ── 项目路径 ──────────────────────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$PROJECT_DIR/venv"
APP_NAME="qwenpaw"
HOST="${QWENPAW_HOST:-0.0.0.0}"
PORT="${QWENPAW_PORT:-8088}"
PID_FILE="$PROJECT_DIR/.qwenpaw.pid"
LOG_FILE="$PROJECT_DIR/qwenpaw.log"

# ── 环境检测与安装 ────────────────────────────────────────────────────────────
check_and_setup_env() {
    info "检测运行环境..."

    # Python 检测
    if ! command -v python3 &>/dev/null; then
        warn "未检测到 python3，尝试安装..."
        if command -v apt-get &>/dev/null; then
            sudo apt-get update && sudo apt-get install -y python3 python3-pip python3-venv
        elif command -v yum &>/dev/null; then
            sudo yum install -y python3 python3-pip
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y python3 python3-pip
        else
            error "无法自动安装 Python3，请手动安装后重试"; exit 1
        fi
    fi

    PYTHON_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    info "Python 版本: $PYTHON_VER"

    # Node.js 检测（构建前端需要）
    if ! command -v node &>/dev/null; then
        warn "未检测到 Node.js，尝试安装..."
        if command -v apt-get &>/dev/null; then
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
            sudo apt-get install -y nodejs
        elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
            curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
            sudo yum install -y nodejs 2>/dev/null || sudo dnf install -y nodejs
        else
            error "无法自动安装 Node.js，请手动安装后重试"; exit 1
        fi
    fi
    info "Node.js 版本: $(node --version)"

    # 虚拟环境
    if [ ! -d "$VENV_DIR" ]; then
        info "创建 Python 虚拟环境..."
        python3 -m venv "$VENV_DIR"
    fi
    source "$VENV_DIR/bin/activate"

    # 检查是否已安装 qwenpaw
    if ! command -v qwenpaw &>/dev/null; then
        info "安装项目依赖（首次安装可能需要几分钟）..."
        build_and_install
    else
        info "qwenpaw 已安装"
    fi

    # 检查是否已初始化
    local working_dir="${QWENPAW_WORKING_DIR:-$PROJECT_DIR/working}"
    if [ ! -f "$working_dir/config.json" ]; then
        info "首次运行，执行初始化..."
        qwenpaw init --defaults --accept-security
    fi
}

# ── 构建与安装 ────────────────────────────────────────────────────────────────
build_and_install() {
    source "$VENV_DIR/bin/activate"

    # 构建前端
    if [ ! -d "$PROJECT_DIR/src/qwenpaw/console/index.html" ] && [ -d "$PROJECT_DIR/console" ]; then
        info "构建前端控制台..."
        cd "$PROJECT_DIR/console"
        npm ci --include=dev
        npm run build
        cd "$PROJECT_DIR"
        mkdir -p src/qwenpaw/console
        cp -R console/dist/. src/qwenpaw/console/
        info "前端构建完成"
    fi

    # 安装 Python 包
    info "安装 Python 依赖..."
    pip install -e . --quiet
    info "安装完成"
}

# ── 激活虚拟环境 ──────────────────────────────────────────────────────────────
activate_venv() {
    if [ -d "$VENV_DIR" ]; then
        source "$VENV_DIR/bin/activate"
    else
        error "虚拟环境不存在，请先运行环境检测"
        exit 1
    fi
}

# ── 启动（前台/后台） ────────────────────────────────────────────────────────
start_app() {
    activate_venv
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        warn "QwenPaw 已在运行 (PID: $(cat "$PID_FILE"))"
        return
    fi
    info "启动 QwenPaw (${HOST}:${PORT})..."
    nohup qwenpaw app --host "$HOST" --port "$PORT" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 2
    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        info "启动成功 (PID: $(cat "$PID_FILE"))"
        info "控制台地址: http://${HOST}:${PORT}/"
    else
        error "启动失败，请查看日志: $LOG_FILE"
        rm -f "$PID_FILE"
    fi
}

# ── 停止 ──────────────────────────────────────────────────────────────────────
stop_app() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            info "停止 QwenPaw (PID: $pid)..."
            kill "$pid"
            sleep 2
            if kill -0 "$pid" 2>/dev/null; then
                warn "进程未响应，强制终止..."
                kill -9 "$pid"
            fi
            info "已停止"
        else
            warn "进程已不存在"
        fi
        rm -f "$PID_FILE"
    else
        warn "未找到运行中的 QwenPaw 进程"
    fi
}

# ── PM2 管理 ──────────────────────────────────────────────────────────────────
ensure_pm2() {
    if ! command -v pm2 &>/dev/null; then
        info "安装 PM2..."
        sudo npm install -g pm2
    fi
}

pm2_start() {
    activate_venv
    ensure_pm2
    local qwenpaw_bin
    qwenpaw_bin="$(which qwenpaw)"

    if pm2 describe "$APP_NAME" &>/dev/null; then
        warn "PM2 中已存在 $APP_NAME，重启中..."
        pm2 restart "$APP_NAME"
    else
        info "通过 PM2 启动 QwenPaw..."
        pm2 start "$qwenpaw_bin" --name "$APP_NAME" \
            --interpreter none \
            -- app --host "$HOST" --port "$PORT"
    fi
    pm2 save
    info "PM2 启动完成，控制台: http://${HOST}:${PORT}/"
}

pm2_stop() {
    ensure_pm2
    if pm2 describe "$APP_NAME" &>/dev/null; then
        info "停止 PM2 进程: $APP_NAME"
        pm2 stop "$APP_NAME"
        info "已停止"
    else
        warn "PM2 中未找到 $APP_NAME"
    fi
}

pm2_delete() {
    ensure_pm2
    if pm2 describe "$APP_NAME" &>/dev/null; then
        info "删除 PM2 进程: $APP_NAME"
        pm2 delete "$APP_NAME"
        pm2 save
        info "已删除"
    else
        warn "PM2 中未找到 $APP_NAME"
    fi
}

# ── 日志 ──────────────────────────────────────────────────────────────────────
show_logs() {
    if pm2 describe "$APP_NAME" &>/dev/null 2>&1; then
        pm2 logs "$APP_NAME" --lines 50
    elif [ -f "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    else
        warn "未找到日志文件"
    fi
}

# ── 重新构建 ──────────────────────────────────────────────────────────────────
rebuild() {
    info "重新构建项目..."
    activate_venv
    # 强制重新构建前端
    rm -rf "$PROJECT_DIR/src/qwenpaw/console"
    build_and_install
    info "重新构建完成，请重启服务"
}

# ── 菜单 ──────────────────────────────────────────────────────────────────────
show_menu() {
    echo ""
    printf "${CYAN}═══════════════════════════════════════${RESET}\n"
    printf "${BOLD}       QwenPaw 部署管理工具${RESET}\n"
    printf "${CYAN}═══════════════════════════════════════${RESET}\n"
    echo ""
    echo "  1) 启动 QwenPaw（后台运行）"
    echo "  2) 停止 QwenPaw"
    echo "  3) 使用 PM2 启动"
    echo "  4) 停止 PM2"
    echo "  5) 删除 PM2 进程"
    echo "  6) 查看日志"
    echo "  7) 重新构建"
    echo "  0) 退出"
    echo ""
    printf "${CYAN}───────────────────────────────────────${RESET}\n"
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
    cd "$PROJECT_DIR"

    # 首次运行自动检测环境
    check_and_setup_env

    while true; do
        show_menu
        printf "  请选择操作 [0-7]: "
        read -r choice
        echo ""
        case "$choice" in
            1) start_app ;;
            2) stop_app ;;
            3) pm2_start ;;
            4) pm2_stop ;;
            5) pm2_delete ;;
            6) show_logs ;;
            7) rebuild ;;
            0) info "再见！"; exit 0 ;;
            *) warn "无效选项，请重新选择" ;;
        esac
    done
}

main "$@"
