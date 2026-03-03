#!/bin/bash

# ============================================================
#  节点一键管理脚本
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

HY2_CONFIG="/etc/hysteria/config.yaml"
HY2_BIN="/usr/local/bin/hysteria"
HY2_SERVICE="hysteria-server"
HY2_CERT_DIR="/etc/hysteria/certs"
HY2_INFO="/root/hysteria2_client_info.txt"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_INFO="/root/reality_client_info.txt"

SS_BIN="/usr/local/bin/ssserver"
SS_CONFIG="/etc/shadowsocks-rust/config.json"
SS_SERVICE="shadowsocks-rust"
SS_INFO="/root/shadowsocks_client_info.txt"

# ============================================================
# 公共工具函数
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

press_enter() {
    echo ""
    read -rp "按 Enter 键继续..." _
}

get_server_ip() {
    local ip
    ip=$(curl -s --max-time 6 https://api4.ipify.org 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s --max-time 6 https://ifconfig.me 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s --max-time 6 https://ipinfo.io/ip 2>/dev/null)
    echo "$ip"
}

input_domain() {
    local server_ip="$1"
    local result_var="$2"
    while true; do
        read -rp "$(echo -e "${CYAN}请输入域名（如 vps.example.com）:${NC} ")" INPUT_D
        INPUT_D=$(echo "$INPUT_D" | tr -d '[:space:]' | sed 's|https*://||g' | sed 's|/.*||g')
        if [[ -z "$INPUT_D" ]]; then warn "域名不能为空。"; continue; fi
        if ! echo "$INPUT_D" | grep -qP '^[a-zA-Z0-9]([a-zA-Z0-9.\-]*[a-zA-Z0-9])?$'; then
            warn "域名格式不正确。"; continue
        fi
        step "正在解析域名 ${INPUT_D}..."
        local resolved
        resolved=$(getent hosts "$INPUT_D" 2>/dev/null | awk '{print $1}' | head -1)
        [[ -z "$resolved" ]] && resolved=$(dig +short "$INPUT_D" 2>/dev/null | tail -1)
        if [[ -n "$resolved" ]]; then
            info "域名解析结果: ${resolved}"
            if [[ "$resolved" == "$server_ip" ]]; then
                success "域名已正确解析到本机 IP"
            else
                warn "域名解析到 ${resolved}，与本机 IP ${server_ip} 不一致"
                read -rp "$(echo -e "${YELLOW}是否仍然使用此域名？(y/N):${NC} ")" FC
                [[ "$FC" != "y" && "$FC" != "Y" ]] && continue
            fi
        else
            warn "无法解析域名 ${INPUT_D}"
            read -rp "$(echo -e "${YELLOW}是否仍然使用此域名？(y/N):${NC} ")" FC
            [[ "$FC" != "y" && "$FC" != "Y" ]] && continue
        fi
        eval "$result_var='$INPUT_D'"
        break
    done
}

choose_server_addr() {
    local server_ip="$1"
    local addr_var="$2"
    local domain_var="$3"
    echo ""
    echo -e "${CYAN}客户端连接地址选择：${NC}"
    echo -e "  ${BOLD}1.${NC} 使用公网 IP  (${server_ip})"
    echo -e "  ${BOLD}2.${NC} 使用解析到此 VPS 的域名"
    read -rp "$(echo -e "${CYAN}请选择 [默认 1]:${NC} ")" AC
    AC="${AC:-1}"
    if [[ "$AC" == "2" ]]; then
        local dval=""
        input_domain "$server_ip" dval
        eval "$addr_var='$dval'"
        eval "$domain_var='$dval'"
    else
        eval "$addr_var='$server_ip'"
        eval "$domain_var=''"
    fi
    info "客户端连接地址: ${BOLD}$(eval echo \$$addr_var)${NC}"
}

get_status() {
    local label="$1" service="$2" bin="$3"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "  ${label}: ${GREEN}● 运行中${NC}"
    elif [[ -f "$bin" ]]; then
        echo -e "  ${label}: ${RED}● 已停止${NC}"
    else
        echo -e "  ${label}: ${YELLOW}● 未安装${NC}"
    fi
}


# ============================================================
# HYSTERIA 2
# ============================================================

hy2_install_core() {
    step "安装 Hysteria 2..."
    apt-get update -qq
    apt-get install -y -qq curl openssl
    bash <(curl -fsSL https://get.hy2.sh/)
    if [[ $? -ne 0 ]]; then error "Hysteria 2 安装失败！"; return 1; fi
    success "Hysteria 2 安装完成: $(hysteria version 2>/dev/null | head -1)"
}

hy2_setup_cert() {
    local domain="$1" server_addr="$2"
    mkdir -p "$HY2_CERT_DIR"
    if [[ -n "$domain" ]]; then
        echo ""
        echo -e "${CYAN}证书申请方式：${NC}"
        echo -e "  ${BOLD}1.${NC} ACME 自动申请 Let's Encrypt 证书"
        echo -e "  ${BOLD}2.${NC} 使用自签证书（客户端需跳过证书验证）"
        read -rp "$(echo -e "${CYAN}请选择 [默认 1]:${NC} ")" CC
        CC="${CC:-1}"
        if [[ "$CC" == "1" ]]; then
            read -rp "$(echo -e "${CYAN}请输入申请证书的邮箱:${NC} ")" ACME_EMAIL
            [[ -z "$ACME_EMAIL" ]] && ACME_EMAIL="admin@${domain}" && warn "使用默认邮箱: ${ACME_EMAIL}"
            CERT_MODE="acme"
            success "将使用 ACME 申请证书，域名: ${domain}"
            return 0
        fi
    fi
    step "生成自签证书..."
    local cn="${domain:-$server_addr}"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "${HY2_CERT_DIR}/private.key" \
        -out    "${HY2_CERT_DIR}/cert.crt"   \
        -days 3650 -subj "/CN=${cn}" 2>/dev/null
    [[ $? -ne 0 ]] && error "自签证书生成失败！" && return 1
    chmod 755 "${HY2_CERT_DIR}"
    chmod 644 "${HY2_CERT_DIR}/cert.crt"
    if id "hysteria" &>/dev/null; then
        chown root:hysteria "${HY2_CERT_DIR}/private.key"
        chmod 640 "${HY2_CERT_DIR}/private.key"
    else
        chmod 644 "${HY2_CERT_DIR}/private.key"
    fi
    CERT_MODE="self"
    success "自签证书已生成: ${HY2_CERT_DIR}/"
}

hy2_generate_config() {
    local port="$1" password="$2" domain="$3" cert_mode="$4"
    mkdir -p /etc/hysteria
    if [[ "$cert_mode" == "acme" ]]; then
        cat > "$HY2_CONFIG" <<EOF
listen: :${port}

acme:
  domains:
    - ${domain}
  email: ${ACME_EMAIL}

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps
EOF
    else
        cat > "$HY2_CONFIG" <<EOF
listen: :${port}

tls:
  cert: ${HY2_CERT_DIR}/cert.crt
  key: ${HY2_CERT_DIR}/private.key

auth:
  type: password
  password: ${password}

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps
EOF
    fi
}

hy2_save_info() {
    local server_addr="$1" port="$2" password="$3" cert_mode="$4" domain="$5"
    local sni_field share_link
    if [[ "$cert_mode" == "self" ]]; then
        sni_field="${domain:-$server_addr}"
        share_link="hysteria2://${password}@${server_addr}:${port}?insecure=1&sni=${sni_field}#Hysteria2-Node"
    else
        sni_field="$domain"
        share_link="hysteria2://${password}@${server_addr}:${port}?sni=${sni_field}#Hysteria2-Node"
    fi
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║         Hysteria 2 节点配置信息               ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}协议${NC}          : Hysteria 2"
    echo -e "  ${CYAN}服务器地址${NC}    : ${BOLD}${server_addr}${NC}"
    echo -e "  ${CYAN}端口${NC}          : ${BOLD}${port}${NC}"
    echo -e "  ${CYAN}密码${NC}          : ${BOLD}${password}${NC}"
    echo -e "  ${CYAN}TLS SNI${NC}       : ${BOLD}${sni_field}${NC}"
    if [[ "$cert_mode" == "self" ]]; then
        echo -e "  ${CYAN}跳过证书验证${NC}  : ${BOLD}${YELLOW}是（自签证书）${NC}"
    else
        echo -e "  ${CYAN}证书${NC}          : ${BOLD}Let's Encrypt${NC}"
    fi
    echo ""
    echo -e "${BOLD}${GREEN}分享链接:${NC}"
    echo -e "${YELLOW}${share_link}${NC}"
    echo ""
    echo -e "${BOLD}${GREEN}客户端配置 (YAML):${NC}"
    if [[ "$cert_mode" == "self" ]]; then
        echo -e "${CYAN}server: ${server_addr}:${port}\nauth: ${password}\ntls:\n  sni: ${sni_field}\n  insecure: true\nbandwidth:\n  up: 50 mbps\n  down: 200 mbps${NC}"
    else
        echo -e "${CYAN}server: ${server_addr}:${port}\nauth: ${password}\ntls:\n  sni: ${sni_field}\nbandwidth:\n  up: 50 mbps\n  down: 200 mbps${NC}"
    fi
    echo ""
    {
        echo "===== Hysteria 2 节点配置信息 ====="
        echo "服务器地址   : ${server_addr}"
        echo "端口         : ${port}"
        echo "密码         : ${password}"
        echo "TLS SNI      : ${sni_field}"
        [[ "$cert_mode" == "self" ]] && echo "跳过证书验证 : 是（自签证书）" || echo "证书         : Let's Encrypt"
        echo ""
        echo "分享链接:"
        echo "${share_link}"
        echo ""
        echo "客户端配置 (YAML):"
        echo "server: ${server_addr}:${port}"
        echo "auth: ${password}"
        echo "tls:"
        echo "  sni: ${sni_field}"
        [[ "$cert_mode" == "self" ]] && echo "  insecure: true"
        echo "bandwidth:"
        echo "  up: 50 mbps"
        echo "  down: 200 mbps"
    } > "$HY2_INFO"
    success "配置信息已保存至 ${HY2_INFO}"
}

hy2_setup() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════ 一键搭建 Hysteria 2 节点 ═══════════${NC}"
    echo ""
    step "获取服务器公网 IP..."
    local SERVER_IP; SERVER_IP=$(get_server_ip)
    info "检测到服务器公网 IP: ${BOLD}${SERVER_IP}${NC}"
    local SERVER_ADDR INPUT_DOMAIN CERT_MODE="" ACME_EMAIL=""
    choose_server_addr "$SERVER_IP" SERVER_ADDR INPUT_DOMAIN
    echo ""
    read -rp "$(echo -e "${CYAN}请输入监听端口 [默认 443]:${NC} ")" INPUT_PORT
    INPUT_PORT="${INPUT_PORT:-443}"
    if ! [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] || [[ "$INPUT_PORT" -lt 1 || "$INPUT_PORT" -gt 65535 ]]; then
        error "端口号无效！"; press_enter; return 1
    fi
    info "使用端口: ${BOLD}${INPUT_PORT}${NC}"
    echo ""
    step "生成随机连接密码..."
    local HY2_PASS; HY2_PASS=$(openssl rand -base64 24 | tr -d '=+/' | cut -c1-20)
    success "连接密码: ${BOLD}${HY2_PASS}${NC}"
    echo ""
    hy2_setup_cert "$INPUT_DOMAIN" "$SERVER_ADDR" || { press_enter; return 1; }
    echo ""
    hy2_install_core || { press_enter; return 1; }
    echo ""
    step "生成配置文件..."
    hy2_generate_config "$INPUT_PORT" "$HY2_PASS" "$INPUT_DOMAIN" "$CERT_MODE"
    success "配置文件已写入 ${HY2_CONFIG}"
    echo ""
    step "启动 Hysteria 2 服务..."
    systemctl enable "$HY2_SERVICE" --quiet 2>/dev/null
    systemctl restart "$HY2_SERVICE"
    sleep 2
    if systemctl is-active --quiet "$HY2_SERVICE"; then
        success "Hysteria 2 服务运行正常！"
    else
        error "Hysteria 2 服务启动失败，查看日志："
        journalctl -u "$HY2_SERVICE" -n 30 --no-pager
        press_enter; return 1
    fi
    hy2_save_info "$SERVER_ADDR" "$INPUT_PORT" "$HY2_PASS" "$CERT_MODE" "$INPUT_DOMAIN"
    press_enter
}

hy2_update() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════ 更新 Hysteria 2 ═══════════${NC}"
    echo ""
    [[ ! -f "$HY2_BIN" ]] && warn "Hysteria 2 未安装，将直接安装..." \
        || info "当前版本: $(hysteria version 2>/dev/null | head -1)"
    bash <(curl -fsSL https://get.hy2.sh/)
    if [[ $? -eq 0 ]]; then
        systemctl restart "$HY2_SERVICE" 2>/dev/null
        success "更新完成！当前版本: $(hysteria version 2>/dev/null | head -1)"
    else
        error "更新失败！"
    fi
    press_enter
}

hy2_remove() {
    echo ""
    echo -e "${BOLD}${RED}═══════════ 移除 Hysteria 2 节点 ═══════════${NC}"
    echo ""
    read -rp "$(echo -e "${RED}确认移除 Hysteria 2 节点及所有配置？(y/N):${NC} ")" C
    if [[ "$C" != "y" && "$C" != "Y" ]]; then info "已取消。"; press_enter; return; fi
    systemctl stop "$HY2_SERVICE" 2>/dev/null
    systemctl disable "$HY2_SERVICE" 2>/dev/null
    bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null
    rm -rf /etc/hysteria
    rm -f "$HY2_INFO"
    success "Hysteria 2 节点已完全移除！"
    press_enter
}

hy2_show_info() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════ 当前 Hysteria 2 节点信息 ═══════════${NC}"
    echo ""
    if [[ ! -f "$HY2_CONFIG" ]]; then warn "未找到配置文件，节点可能尚未搭建。"; press_enter; return; fi
    if [[ -f "$HY2_INFO" ]]; then cat "$HY2_INFO"; else info "配置文件内容："; cat "$HY2_CONFIG"; fi
    echo ""
    echo -e "${CYAN}服务状态:${NC}"
    systemctl status "$HY2_SERVICE" --no-pager -l | head -10
    press_enter
}

hy2_menu() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${BLUE}  ╔══════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${BLUE}  ║        Hysteria 2 节点管理               ║${NC}"
        echo -e "${BOLD}${BLUE}  ╚══════════════════════════════════════════╝${NC}"
        echo ""
        if systemctl is-active --quiet "$HY2_SERVICE" 2>/dev/null; then
            echo -e "  状态: ${GREEN}● 运行中${NC}"
        elif [[ -f "$HY2_BIN" ]]; then
            echo -e "  状态: ${RED}● 已停止${NC}"
        else
            echo -e "  状态: ${YELLOW}● 未安装${NC}"
        fi
        echo ""
        echo -e "  ${BOLD}1.${NC} 一键搭建 Hysteria 2 节点"
        echo -e "  ${BOLD}2.${NC} 更新 Hysteria 2"
        echo -e "  ${BOLD}3.${NC} 移除 Hysteria 2 节点"
        echo -e "  ${BOLD}4.${NC} 查看当前节点信息与分享链接"
        echo -e "  ${BOLD}5.${NC} 返回上级菜单"
        echo ""
        echo -e "${BLUE}══════════════════════════════════════════════${NC}"
        read -rp "$(echo -e "${CYAN}请输入选项 [1-5]:${NC} ")" CH
        case "$CH" in
            1) hy2_setup    ;;
            2) hy2_update   ;;
            3) hy2_remove   ;;
            4) hy2_show_info ;;
            5) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}


# ============================================================
# REALITY (VLESS + Xray)
# ============================================================

reality_get_best_sni() {
    step "正在获取 VPS 地理位置，自动优选伪装网站..."
    local country=""
    country=$(curl -s --max-time 6 "https://ipapi.co/country" 2>/dev/null)
    [[ -z "$country" ]] && country=$(curl -s --max-time 6 "https://ipinfo.io/country" 2>/dev/null)
    info "检测到 VPS 所在地区: ${BOLD}${country:-未知}${NC}"
    local SNI_LIST=()
    case "$country" in
        US|CA|MX) SNI_LIST=("www.apple.com" "www.microsoft.com" "login.microsoftonline.com" "ajax.googleapis.com" "dl.google.com" "www.icloud.com" "itunes.apple.com" "swdist.apple.com" "www.amazon.com" "s3.amazonaws.com" "www.cloudflare.com" "one.one.one.one" "www.netflix.com" "fast.com" "www.github.com" "github.githubassets.com" "api.github.com" "www.twitch.tv" "discord.com" "www.reddit.com") ;;
        GB|DE|FR|NL|SE|NO|FI|DK|CH|AT|BE|IE|ES|IT|PT) SNI_LIST=("www.microsoft.com" "login.microsoftonline.com" "www.office.com" "www.apple.com" "www.icloud.com" "www.amazon.co.uk" "www.amazon.de" "s3.amazonaws.com" "www.cloudflare.com" "cdn.cloudflare.com" "www.github.com" "github.githubassets.com" "dl.google.com" "www.gstatic.com" "www.netflix.com" "www.spotify.com" "open.spotify.com" "discord.com" "www.twitch.tv" "www.reddit.com") ;;
        JP|KR|TW) SNI_LIST=("www.apple.com" "swdist.apple.com" "www.icloud.com" "www.microsoft.com" "login.microsoftonline.com" "www.office.com" "dl.google.com" "www.gstatic.com" "ajax.googleapis.com" "www.cloudflare.com" "cdn.cloudflare.com" "www.github.com" "github.githubassets.com" "www.amazon.co.jp" "www.netflix.com" "www.twitch.tv" "discord.com" "www.dropbox.com" "www.zoom.us" "assets.zoom.us") ;;
        SG|HK|MY|TH|ID|PH|VN) SNI_LIST=("www.apple.com" "www.icloud.com" "swdist.apple.com" "www.microsoft.com" "login.microsoftonline.com" "dl.google.com" "www.gstatic.com" "www.cloudflare.com" "cdn.cloudflare.com" "www.github.com" "github.githubassets.com" "www.amazon.com" "s3.amazonaws.com" "www.netflix.com" "www.zoom.us" "assets.zoom.us" "discord.com" "www.dropbox.com" "www.fastly.com" "global.alicdn.com") ;;
        AU|NZ) SNI_LIST=("www.apple.com" "www.icloud.com" "www.microsoft.com" "www.office.com" "dl.google.com" "www.gstatic.com" "www.cloudflare.com" "www.amazon.com.au" "s3.amazonaws.com" "www.github.com" "github.githubassets.com" "www.netflix.com" "www.spotify.com" "discord.com" "www.twitch.tv" "www.dropbox.com" "www.zoom.us" "www.reddit.com" "cdn.cloudflare.com" "www.fastly.com") ;;
        AE|SA|TR|ZA|EG|NG|KE) SNI_LIST=("www.microsoft.com" "login.microsoftonline.com" "www.office.com" "www.apple.com" "www.icloud.com" "www.cloudflare.com" "cdn.cloudflare.com" "dl.google.com" "www.gstatic.com" "www.amazon.com" "s3.amazonaws.com" "www.github.com" "github.githubassets.com" "www.zoom.us" "www.netflix.com" "discord.com" "www.dropbox.com" "www.fastly.com" "www.reddit.com" "www.twitch.tv") ;;
        *) SNI_LIST=("www.microsoft.com" "login.microsoftonline.com" "www.office.com" "www.apple.com" "www.icloud.com" "swdist.apple.com" "dl.google.com" "www.gstatic.com" "ajax.googleapis.com" "www.cloudflare.com" "cdn.cloudflare.com" "www.github.com" "github.githubassets.com" "api.github.com" "www.amazon.com" "s3.amazonaws.com" "www.netflix.com" "www.zoom.us" "discord.com" "www.dropbox.com") ;;
    esac
    step "正在测试伪装网站连通性，请稍候..."
    local best_sni="" best_time=9999
    for sni in "${SNI_LIST[@]}"; do
        local t t_ms
        t=$(curl -o /dev/null -s -w "%{time_connect}" --max-time 5 --tlsv1.3 "https://${sni}" 2>/dev/null)
        t_ms=$(echo "$t" | awk '{printf "%d", $1*1000}')
        if [[ $t_ms -gt 0 && $t_ms -lt $best_time ]]; then best_time=$t_ms; best_sni="$sni"; fi
        echo -e "   ${sni}  =>  ${t_ms}ms"
    done
    if [[ -z "$best_sni" ]]; then
        warn "无法测速，使用默认: www.microsoft.com"
        best_sni="www.microsoft.com"
    else
        success "最优伪装网站: ${BOLD}${best_sni}${NC} (${best_time}ms)"
    fi
    BEST_SNI="$best_sni"
}

reality_generate_config() {
    local port="$1" uuid="$2" private_key="$3" sni="$4"
    mkdir -p /usr/local/etc/xray
    cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${sni}:443",
          "xver": 0,
          "serverNames": ["${sni}"],
          "privateKey": "${private_key}",
          "shortIds": [""]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
}

reality_save_info() {
    local port="$1" uuid="$2" public_key="$3" sni="$4" server_addr="$5"
    local share_link="vless://${uuid}@${server_addr}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${public_key}&type=tcp#Reality-Node"
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║         Reality 节点配置信息                  ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}协议${NC}          : VLESS"
    echo -e "  ${CYAN}服务器地址${NC}    : ${BOLD}${server_addr}${NC}"
    echo -e "  ${CYAN}端口${NC}          : ${BOLD}${port}${NC}"
    echo -e "  ${CYAN}UUID${NC}          : ${BOLD}${uuid}${NC}"
    echo -e "  ${CYAN}Flow${NC}          : xtls-rprx-vision"
    echo -e "  ${CYAN}传输协议${NC}      : TCP"
    echo -e "  ${CYAN}TLS${NC}           : Reality"
    echo -e "  ${CYAN}SNI${NC}           : ${BOLD}${sni}${NC}"
    echo -e "  ${CYAN}PublicKey${NC}     : ${BOLD}${public_key}${NC}"
    echo -e "  ${CYAN}ShortId${NC}       : (留空)"
    echo -e "  ${CYAN}Fingerprint${NC}   : chrome"
    echo ""
    echo -e "${BOLD}${GREEN}分享链接:${NC}"
    echo -e "${YELLOW}${share_link}${NC}"
    echo ""
    {
        echo "===== Reality 节点配置信息 ====="
        echo "服务器地址 : ${server_addr}"
        echo "端口       : ${port}"
        echo "UUID       : ${uuid}"
        echo "Flow       : xtls-rprx-vision"
        echo "传输协议   : TCP"
        echo "TLS        : Reality"
        echo "SNI        : ${sni}"
        echo "PublicKey  : ${public_key}"
        echo "ShortId    : (留空)"
        echo "Fingerprint: chrome"
        echo ""
        echo "分享链接:"
        echo "${share_link}"
    } > "$XRAY_INFO"
    success "配置信息已保存至 ${XRAY_INFO}"
}

reality_setup() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════ 一键搭建 Reality 节点 ═══════════${NC}"
    echo ""
    step "获取服务器公网 IP..."
    local SERVER_IP; SERVER_IP=$(get_server_ip)
    info "检测到服务器公网 IP: ${BOLD}${SERVER_IP}${NC}"
    local SERVER_ADDR INPUT_DOMAIN BEST_SNI=""
    choose_server_addr "$SERVER_IP" SERVER_ADDR INPUT_DOMAIN
    echo ""
    read -rp "$(echo -e "${CYAN}请输入监听端口 [默认 443]:${NC} ")" INPUT_PORT
    INPUT_PORT="${INPUT_PORT:-443}"
    if ! [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] || [[ "$INPUT_PORT" -lt 1 || "$INPUT_PORT" -gt 65535 ]]; then
        error "端口号无效！"; press_enter; return 1
    fi
    info "使用端口: ${BOLD}${INPUT_PORT}${NC}"
    echo ""
    reality_get_best_sni
    echo ""
    step "安装/更新 Xray-core..."
    apt-get update -qq && apt-get install -y -qq curl unzip
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [[ $? -ne 0 ]]; then error "Xray 安装失败！"; press_enter; return 1; fi
    success "Xray-core 安装完成"
    echo ""
    step "生成密钥对和 UUID..."
    local KEYPAIR_OUTPUT; KEYPAIR_OUTPUT=$("$XRAY_BIN" x25519 2>&1)
    local PRIVATE_KEY PUBLIC_KEY UUID
    PRIVATE_KEY=$(echo "$KEYPAIR_OUTPUT" | grep -iE "^PrivateKey:|^Private key:" | awk -F': ' '{print $2}' | tr -d '[:space:]')
    PUBLIC_KEY=$(echo  "$KEYPAIR_OUTPUT" | grep -iE "^Password:|^Public key:"    | awk -F': ' '{print $2}' | tr -d '[:space:]')
    [[ -z "$PRIVATE_KEY" ]] && PRIVATE_KEY=$(echo "$KEYPAIR_OUTPUT" | sed -n '1p' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    [[ -z "$PUBLIC_KEY"  ]] && PUBLIC_KEY=$(echo  "$KEYPAIR_OUTPUT" | sed -n '2p' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        error "密钥对生成失败！原始输出:"; echo "$KEYPAIR_OUTPUT"; press_enter; return 1
    fi
    UUID=$("$XRAY_BIN" uuid 2>&1 | tr -d '[:space:]')
    [[ -z "$UUID" ]] && error "UUID 生成失败！" && press_enter && return 1
    success "UUID : ${UUID}"
    success "私钥 : ${PRIVATE_KEY}"
    success "公钥 : ${PUBLIC_KEY}"
    echo ""
    step "生成配置文件..."
    reality_generate_config "$INPUT_PORT" "$UUID" "$PRIVATE_KEY" "$BEST_SNI"
    success "配置文件已写入 ${XRAY_CONFIG}"
    echo ""
    step "启动 Xray 服务..."
    systemctl enable xray --quiet
    systemctl restart xray
    sleep 2
    if systemctl is-active --quiet xray; then
        success "Xray 服务运行正常！"
    else
        error "Xray 服务启动失败，查看日志："
        journalctl -u xray -n 20 --no-pager
        press_enter; return 1
    fi
    reality_save_info "$INPUT_PORT" "$UUID" "$PUBLIC_KEY" "$BEST_SNI" "$SERVER_ADDR"
    press_enter
}

reality_update() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════ 更新 Xray-core ═══════════${NC}"
    echo ""
    [[ ! -f "$XRAY_BIN" ]] && warn "Xray 未安装，将直接安装..." \
        || info "当前版本: $("$XRAY_BIN" version 2>/dev/null | head -1)"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    if [[ $? -eq 0 ]]; then
        systemctl restart xray 2>/dev/null
        success "更新完成！当前版本: $("$XRAY_BIN" version 2>/dev/null | head -1)"
    else
        error "更新失败！"
    fi
    press_enter
}

reality_remove() {
    echo ""
    echo -e "${BOLD}${RED}═══════════ 移除节点及所有配置 ═══════════${NC}"
    echo ""
    read -rp "$(echo -e "${RED}确认移除 Reality 节点及所有配置？(y/N):${NC} ")" C
    if [[ "$C" != "y" && "$C" != "Y" ]]; then info "已取消。"; press_enter; return; fi
    systemctl stop xray 2>/dev/null
    systemctl disable xray 2>/dev/null
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove 2>/dev/null
    rm -rf /usr/local/etc/xray
    rm -f "$XRAY_INFO"
    success "Reality 节点及所有配置已完全移除！"
    press_enter
}

reality_show_info() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════ 当前 Reality 节点信息 ═══════════${NC}"
    echo ""
    if [[ ! -f "$XRAY_CONFIG" ]]; then warn "未找到配置文件，节点可能尚未搭建。"; press_enter; return; fi
    if [[ -f "$XRAY_INFO" ]]; then cat "$XRAY_INFO"; else info "配置文件内容："; cat "$XRAY_CONFIG"; fi
    echo ""
    echo -e "${CYAN}Xray 服务状态:${NC}"
    systemctl status xray --no-pager -l | head -10
    press_enter
}

reality_menu() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${BLUE}  ╔══════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${BLUE}  ║       VLESS + Reality 节点管理           ║${NC}"
        echo -e "${BOLD}${BLUE}  ╚══════════════════════════════════════════╝${NC}"
        echo ""
        if systemctl is-active --quiet xray 2>/dev/null; then
            echo -e "  状态: ${GREEN}● 运行中${NC}"
        elif [[ -f "$XRAY_BIN" ]]; then
            echo -e "  状态: ${RED}● 已停止${NC}"
        else
            echo -e "  状态: ${YELLOW}● 未安装${NC}"
        fi
        echo ""
        echo -e "  ${BOLD}1.${NC} 一键搭建 Reality 节点"
        echo -e "  ${BOLD}2.${NC} 更新 Xray-core"
        echo -e "  ${BOLD}3.${NC} 移除节点及所有配置"
        echo -e "  ${BOLD}4.${NC} 查看当前节点信息与分享链接"
        echo -e "  ${BOLD}5.${NC} 返回上级菜单"
        echo ""
        echo -e "${BLUE}══════════════════════════════════════════════${NC}"
        read -rp "$(echo -e "${CYAN}请输入选项 [1-5]:${NC} ")" CH
        case "$CH" in
            1) reality_setup     ;;
            2) reality_update    ;;
            3) reality_remove    ;;
            4) reality_show_info ;;
            5) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}


# ============================================================
# SHADOWSOCKS-RUST
# ============================================================

ss_get_latest_version() {
    curl -s --max-time 10 \
        "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" \
        | grep '"tag_name"' | head -1 | grep -oP 'v[\d.]+' | head -1
}

ss_install_core() {
    step "获取 shadowsocks-rust 最新版本..."
    local version; version=$(ss_get_latest_version)
    if [[ -z "$version" ]]; then error "无法获取最新版本信息！"; return 1; fi
    info "最新版本: ${version}"
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64)  arch_str="x86_64-unknown-linux-gnu" ;;
        aarch64) arch_str="aarch64-unknown-linux-gnu" ;;
        armv7l)  arch_str="armv7-unknown-linux-gnueabihf" ;;
        *) error "不支持的架构: ${arch}"; return 1 ;;
    esac
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${version}/shadowsocks-${version}.${arch_str}.tar.xz"
    local tmp_dir; tmp_dir=$(mktemp -d)
    step "下载 shadowsocks-rust ${version}..."
    curl -L --max-time 120 "$url" -o "${tmp_dir}/ss.tar.xz"
    if [[ $? -ne 0 ]]; then error "下载失败！"; rm -rf "$tmp_dir"; return 1; fi
    step "解压安装..."
    apt-get install -y -qq xz-utils 2>/dev/null
    tar -xJf "${tmp_dir}/ss.tar.xz" -C "$tmp_dir"
    cp -f "${tmp_dir}/ssserver" /usr/local/bin/ssserver
    cp -f "${tmp_dir}/sslocal"  /usr/local/bin/sslocal 2>/dev/null || true
    chmod +x /usr/local/bin/ssserver
    rm -rf "$tmp_dir"
    cat > /etc/systemd/system/${SS_SERVICE}.service <<EOF
[Unit]
Description=Shadowsocks-Rust Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ssserver -c ${SS_CONFIG}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    success "shadowsocks-rust ${version} 安装完成"
}

ss_generate_config() {
    local port="$1" password="$2" method="$3"
    mkdir -p /etc/shadowsocks-rust
    cat > "$SS_CONFIG" <<EOF
{
    "server": "0.0.0.0",
    "server_port": ${port},
    "password": "${password}",
    "method": "${method}",
    "timeout": 300,
    "mode": "tcp_and_udp",
    "fast_open": false
}
EOF
}

ss_save_info() {
    local server_addr="$1" port="$2" password="$3" method="$4"
    local userinfo; userinfo=$(echo -n "${method}:${password}" | base64 | tr -d '\n')
    local share_link="ss://${userinfo}@${server_addr}:${port}#SS-Rust-Node"
    echo ""
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║      Shadowsocks-Rust 节点配置信息            ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}协议${NC}          : Shadowsocks"
    echo -e "  ${CYAN}服务器地址${NC}    : ${BOLD}${server_addr}${NC}"
    echo -e "  ${CYAN}端口${NC}          : ${BOLD}${port}${NC}"
    echo -e "  ${CYAN}密码${NC}          : ${BOLD}${password}${NC}"
    echo -e "  ${CYAN}加密方式${NC}      : ${BOLD}${method}${NC}"
    echo -e "  ${CYAN}传输协议${NC}      : TCP + UDP"
    echo ""
    echo -e "${BOLD}${GREEN}分享链接:${NC}"
    echo -e "${YELLOW}${share_link}${NC}"
    echo ""
    {
        echo "===== Shadowsocks-Rust 节点配置信息 ====="
        echo "服务器地址 : ${server_addr}"
        echo "端口       : ${port}"
        echo "密码       : ${password}"
        echo "加密方式   : ${method}"
        echo "传输协议   : TCP + UDP"
        echo ""
        echo "分享链接:"
        echo "${share_link}"
    } > "$SS_INFO"
    success "配置信息已保存至 ${SS_INFO}"
}

ss_setup() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════ 一键搭建 Shadowsocks-Rust 节点 ═══════════${NC}"
    echo ""
    step "获取服务器公网 IP..."
    local SERVER_IP; SERVER_IP=$(get_server_ip)
    info "检测到服务器公网 IP: ${BOLD}${SERVER_IP}${NC}"
    local SERVER_ADDR INPUT_DOMAIN
    choose_server_addr "$SERVER_IP" SERVER_ADDR INPUT_DOMAIN
    echo ""
    read -rp "$(echo -e "${CYAN}请输入监听端口 [默认 8388]:${NC} ")" INPUT_PORT
    INPUT_PORT="${INPUT_PORT:-8388}"
    if ! [[ "$INPUT_PORT" =~ ^[0-9]+$ ]] || [[ "$INPUT_PORT" -lt 1 || "$INPUT_PORT" -gt 65535 ]]; then
        error "端口号无效！"; press_enter; return 1
    fi
    info "使用端口: ${BOLD}${INPUT_PORT}${NC}"
    echo ""
    echo -e "${CYAN}请选择加密方式：${NC}"
    echo -e "  ${BOLD}1.${NC} aes-256-gcm              （推荐，兼容性好）"
    echo -e "  ${BOLD}2.${NC} chacha20-ietf-poly1305   （推荐，移动端性能好）"
    echo -e "  ${BOLD}3.${NC} aes-128-gcm"
    echo -e "  ${BOLD}4.${NC} 2022-blake3-aes-256-gcm  （最新 SS2022 协议）"
    read -rp "$(echo -e "${CYAN}请选择 [默认 2]:${NC} ")" METHOD_CHOICE
    case "${METHOD_CHOICE:-2}" in
        1) SS_METHOD="aes-256-gcm" ;;
        3) SS_METHOD="aes-128-gcm" ;;
        4) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        *) SS_METHOD="chacha20-ietf-poly1305" ;;
    esac
    info "加密方式: ${BOLD}${SS_METHOD}${NC}"
    echo ""
    step "生成随机密码..."
    local SS_PASS; SS_PASS=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-24)
    success "连接密码: ${BOLD}${SS_PASS}${NC}"
    echo ""
    apt-get update -qq && apt-get install -y -qq curl openssl xz-utils
    ss_install_core || { press_enter; return 1; }
    echo ""
    step "生成配置文件..."
    ss_generate_config "$INPUT_PORT" "$SS_PASS" "$SS_METHOD"
    success "配置文件已写入 ${SS_CONFIG}"
    echo ""
    step "启动 Shadowsocks-Rust 服务..."
    systemctl enable "$SS_SERVICE" --quiet
    systemctl restart "$SS_SERVICE"
    sleep 2
    if systemctl is-active --quiet "$SS_SERVICE"; then
        success "Shadowsocks-Rust 服务运行正常！"
    else
        error "服务启动失败，查看日志："
        journalctl -u "$SS_SERVICE" -n 20 --no-pager
        press_enter; return 1
    fi
    ss_save_info "$SERVER_ADDR" "$INPUT_PORT" "$SS_PASS" "$SS_METHOD"
    press_enter
}

ss_update() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════ 更新 Shadowsocks-Rust ═══════════${NC}"
    echo ""
    local cur_ver=""
    [[ -f "$SS_BIN" ]] && cur_ver=$("$SS_BIN" --version 2>/dev/null | head -1)
    [[ -n "$cur_ver" ]] && info "当前版本: ${cur_ver}" || warn "shadowsocks-rust 未安装，将直接安装..."
    systemctl stop "$SS_SERVICE" 2>/dev/null
    ss_install_core
    if [[ $? -eq 0 ]]; then
        systemctl start "$SS_SERVICE" 2>/dev/null
        success "更新完成！当前版本: $("$SS_BIN" --version 2>/dev/null | head -1)"
    else
        error "更新失败！"
    fi
    press_enter
}

ss_remove() {
    echo ""
    echo -e "${BOLD}${RED}═══════════ 卸载 Shadowsocks-Rust ═══════════${NC}"
    echo ""
    read -rp "$(echo -e "${RED}确认卸载 Shadowsocks-Rust 及所有配置？(y/N):${NC} ")" C
    if [[ "$C" != "y" && "$C" != "Y" ]]; then info "已取消。"; press_enter; return; fi
    systemctl stop "$SS_SERVICE" 2>/dev/null
    systemctl disable "$SS_SERVICE" 2>/dev/null
    rm -f /etc/systemd/system/${SS_SERVICE}.service
    systemctl daemon-reload
    rm -f /usr/local/bin/ssserver /usr/local/bin/sslocal
    rm -rf /etc/shadowsocks-rust
    rm -f "$SS_INFO"
    success "Shadowsocks-Rust 已完全卸载！"
    press_enter
}

ss_show_info() {
    echo ""
    echo -e "${BOLD}${GREEN}═══════════ 当前 Shadowsocks-Rust 节点信息 ═══════════${NC}"
    echo ""
    if [[ ! -f "$SS_CONFIG" ]]; then warn "未找到配置文件，节点可能尚未搭建。"; press_enter; return; fi
    if [[ -f "$SS_INFO" ]]; then cat "$SS_INFO"; else info "配置文件内容："; cat "$SS_CONFIG"; fi
    echo ""
    echo -e "${CYAN}服务状态:${NC}"
    systemctl status "$SS_SERVICE" --no-pager -l | head -10
    press_enter
}

ss_menu() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${BLUE}  ╔══════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${BLUE}  ║      Shadowsocks-Rust 节点管理           ║${NC}"
        echo -e "${BOLD}${BLUE}  ╚══════════════════════════════════════════╝${NC}"
        echo ""
        if systemctl is-active --quiet "$SS_SERVICE" 2>/dev/null; then
            echo -e "  状态: ${GREEN}● 运行中${NC}"
        elif [[ -f "$SS_BIN" ]]; then
            echo -e "  状态: ${RED}● 已停止${NC}"
        else
            echo -e "  状态: ${YELLOW}● 未安装${NC}"
        fi
        echo ""
        echo -e "  ${BOLD}1.${NC} 一键搭建 Shadowsocks-Rust 节点"
        echo -e "  ${BOLD}2.${NC} 更新到最新版本"
        echo -e "  ${BOLD}3.${NC} 卸载 Shadowsocks-Rust"
        echo -e "  ${BOLD}4.${NC} 当前节点信息与分享链接"
        echo -e "  ${BOLD}5.${NC} 返回上级菜单"
        echo ""
        echo -e "${BLUE}══════════════════════════════════════════════${NC}"
        read -rp "$(echo -e "${CYAN}请输入选项 [1-5]:${NC} ")" CH
        case "$CH" in
            1) ss_setup     ;;
            2) ss_update    ;;
            3) ss_remove    ;;
            4) ss_show_info ;;
            5) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}


# ============================================================
# 删除脚本自身
# ============================================================

delete_script() {
    echo ""
    echo -e "${BOLD}${RED}═══════════ 删除脚本 ═══════════${NC}"
    echo ""
    local SCRIPT_PATH; SCRIPT_PATH=$(realpath "$0" 2>/dev/null || echo "$0")
    info "脚本路径: ${SCRIPT_PATH}"
    echo ""
    read -rp "$(echo -e "${RED}确认删除此脚本文件？(y/N):${NC} ")" C
    if [[ "$C" != "y" && "$C" != "Y" ]]; then info "已取消。"; sleep 1; return; fi
    rm -f "$SCRIPT_PATH"
    success "脚本已删除：${SCRIPT_PATH}"
    info "退出脚本..."
    sleep 1
    exit 0
}

# ============================================================
# 快捷命令安装/卸载（输入 n 调出脚本）
# ============================================================

install_shortcut() {
    local script_path
    script_path=$(realpath "$0" 2>/dev/null || echo "$0")
    local shortcut="/usr/local/bin/n"

    # 创建全局命令 n
    cat > "$shortcut" <<EOF
#!/bin/bash
exec bash "${script_path}"
EOF
    chmod +x "$shortcut"
    success "快捷命令已安装！现在可在任意位置输入 ${BOLD}n${NC} 来调出节点管理脚本。"
}

remove_shortcut() {
    if [[ -f /usr/local/bin/n ]]; then
        rm -f /usr/local/bin/n
        success "快捷命令 n 已移除。"
    else
        warn "快捷命令 n 不存在，无需移除。"
    fi
}

# ============================================================
# 主菜单
# ============================================================

main_menu() {
    while true; do
        clear
        echo ""
        echo -e "${BOLD}${BLUE}  ╔════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${BLUE}  ║          节点一键管理脚本                   ║${NC}"
        echo -e "${BOLD}${BLUE}  ║       Debian 12 / Ubuntu 22.04+            ║${NC}"
        echo -e "${BOLD}${BLUE}  ╚════════════════════════════════════════════╝${NC}"
        echo ""
        get_status "Hysteria 2      " "$HY2_SERVICE" "$HY2_BIN"
        get_status "Reality (Xray)  " "xray" "$XRAY_BIN"
        get_status "Shadowsocks-Rust" "$SS_SERVICE" "$SS_BIN"
        echo ""
        # 快捷命令状态
        if [[ -f /usr/local/bin/n ]]; then
            echo -e "  快捷命令 ${BOLD}n${NC}: ${GREEN}● 已安装${NC}"
        else
            echo -e "  快捷命令 ${BOLD}n${NC}: ${YELLOW}● 未安装${NC}"
        fi
        echo ""
        echo -e "  ${BOLD}1.${NC} 一键搭建 Hysteria 2 节点"
        echo -e "  ${BOLD}2.${NC} 一键搭建 Reality 节点"
        echo -e "  ${BOLD}3.${NC} 一键搭建 Shadowsocks-Rust 节点"
        echo -e "  ${BOLD}4.${NC} 安装快捷命令 n"
        echo -e "  ${BOLD}5.${NC} 卸载快捷命令 n"
        echo -e "  ${BOLD}6.${NC} 退出脚本"
        echo -e "  ${BOLD}7.${NC} 删除脚本"
        echo ""
        echo -e "${BLUE}════════════════════════════════════════════════${NC}"
        read -rp "$(echo -e "${CYAN}请输入选项 [1-7]:${NC} ")" CHOICE
        case "$CHOICE" in
            1) hy2_menu     ;;
            2) reality_menu ;;
            3) ss_menu      ;;
            4) install_shortcut; press_enter ;;
            5) remove_shortcut;  press_enter ;;
            6) echo ""; info "已退出脚本，再见！"; echo ""; exit 0 ;;
            7) delete_script ;;
            *) warn "无效选项，请输入 1-7"; sleep 1 ;;
        esac
    done
}

check_root

# 首次运行时自动安装快捷命令 n
if [[ ! -f /usr/local/bin/n ]]; then
    install_shortcut
fi

main_menu
