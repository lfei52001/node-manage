#!/bin/bash

# ============================================================
#  节点管理脚本 - 统一入口
#  包含: Hysteria 2 / VLESS+Reality / Shadowsocks-Rust
#  支持系统: Debian 12 / Ubuntu 22.04+
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

REALITY_SCRIPT="https://raw.githubusercontent.com/lfei52001/reality-node-script/refs/heads/main/reality.sh"
HYSTERIA2_SCRIPT="https://raw.githubusercontent.com/lfei52001/Hysteria2-install/refs/heads/main/hysteria2.sh"
SS_SCRIPT="https://raw.githubusercontent.com/lfei52001/shadowsocks-rust-install/refs/heads/main/ss-manager.sh"

# ============================================================
# 工具函数
# ============================================================

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
success() { echo -e "${GREEN}[✓]${NC} $*"; }
step()    { echo -e "${CYAN}[*]${NC} $*"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 权限运行此脚本！"
        exit 1
    fi
}

# ============================================================
# 运行远程子脚本
# ============================================================

run_script() {
    local name="$1"
    local url="$2"

    echo ""
    step "正在拉取 ${name} 脚本..."
    local tmp
    tmp=$(mktemp /tmp/node_script_XXXXXX.sh)

    curl -sSL "$url" -o "$tmp" 2>/dev/null
    if [[ $? -ne 0 || ! -s "$tmp" ]]; then
        error "脚本下载失败，请检查网络或 URL 是否有效！"
        rm -f "$tmp"
        read -rp "按 Enter 键返回主菜单..." _
        return 1
    fi

    # 统一转换换行符，避免 CRLF 问题
    sed -i 's/\r//' "$tmp"
    chmod +x "$tmp"

    success "${name} 脚本已就绪，正在启动..."
    echo ""
    bash "$tmp"
    local exit_code=$?

    rm -f "$tmp"

    if [[ $exit_code -ne 0 ]]; then
        warn "${name} 脚本执行完毕（退出码: ${exit_code}）"
    fi

    echo ""
    read -rp "按 Enter 键返回主菜单..." _
}

# ============================================================
# 删除脚本自身
# ============================================================

delete_script() {
    echo ""
    echo -e "${BOLD}${RED}═══════════ 删除脚本 ═══════════${NC}"
    echo ""

    SCRIPT_PATH=$(realpath "$0" 2>/dev/null || echo "$0")
    info "脚本路径: ${SCRIPT_PATH}"
    echo ""
    read -rp "$(echo -e "${RED}确认删除此脚本文件？(y/N):${NC} ")" CONFIRM
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        info "已取消操作。"
        read -rp "按 Enter 键返回主菜单..." _
        return
    fi

    rm -f "$SCRIPT_PATH"
    success "脚本已删除：${SCRIPT_PATH}"
    echo ""
    info "退出脚本..."
    sleep 1
    exit 0
}

# ============================================================
# 获取各节点运行状态
# ============================================================

get_status() {
    local label="$1"
    local service="$2"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "  ${label}: ${GREEN}● 运行中${NC}"
    elif systemctl list-unit-files --quiet "$service" 2>/dev/null | grep -q "$service"; then
        echo -e "  ${label}: ${RED}● 已停止${NC}"
    else
        echo -e "  ${label}: ${YELLOW}● 未安装${NC}"
    fi
}

# ============================================================
# 主菜单
# ============================================================

show_menu() {
    clear
    echo ""
    echo -e "${BOLD}${BLUE}  ╔════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}  ║          节点一键管理脚本                   ║${NC}"
    echo -e "${BOLD}${BLUE}  ║       Debian 12 / Ubuntu 22.04+            ║${NC}"
    echo -e "${BOLD}${BLUE}  ╚════════════════════════════════════════════╝${NC}"
    echo ""

    # 显示各节点运行状态
    get_status "Hysteria 2      " "hysteria-server"
    get_status "Reality (Xray)  " "xray"
    get_status "Shadowsocks-Rust" "shadowsocks-rust"

    echo ""
    echo -e "  ${BOLD}1.${NC} 一键搭建 Hysteria 2 节点"
    echo -e "  ${BOLD}2.${NC} 一键搭建 Reality 节点"
    echo -e "  ${BOLD}3.${NC} 一键搭建 Shadowsocks-Rust 节点"
    echo -e "  ${BOLD}4.${NC} 退出脚本"
    echo -e "  ${BOLD}5.${NC} 删除脚本"
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════${NC}"
}

# ============================================================
# 主程序
# ============================================================

main() {
    check_root

    while true; do
        show_menu
        read -rp "$(echo -e "${CYAN}请输入选项 [1-5]:${NC} ")" CHOICE
        case "$CHOICE" in
            1) run_script "Hysteria 2"       "$HYSTERIA2_SCRIPT" ;;
            2) run_script "Reality"          "$REALITY_SCRIPT"   ;;
            3) run_script "Shadowsocks-Rust" "$SS_SCRIPT"        ;;
            4)
                echo ""
                info "已退出脚本，再见！"
                echo ""
                exit 0
                ;;
            5) delete_script ;;
            *)
                warn "无效选项，请输入 1-5"
                sleep 1
                ;;
        esac
    done
}

main
