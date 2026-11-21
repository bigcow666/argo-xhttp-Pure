#!/bin/sh

# 固定持久化配置目录（所有参数独立文件存储，永不丢失）
PERSIST_DIR="/etc/argo-xhttp"
XRAY_CONF_DIR="/usr/local/etc/xray"
mkdir -p "$PERSIST_DIR" "$XRAY_CONF_DIR"
chmod 700 "$PERSIST_DIR"

UUID_FILE="${PERSIST_DIR}/uuid"
PATH_FILE="${PERSIST_DIR}/path"
MODE_FILE="${PERSIST_DIR}/mode"
ARGO_PORT_FILE="${PERSIST_DIR}/argo_port"
DOMAIN_FILE="${PERSIST_DIR}/domain"
TOKEN_FILE="${PERSIST_DIR}/token"
ADDR_FILE="${PERSIST_DIR}/addr"
DEC_FILE="${PERSIST_DIR}/decryption"
ENC_FILE="${PERSIST_DIR}/encryption"
FLOW_FILE="${PERSIST_DIR}/flow"
LINK_FILE="${PERSIST_DIR}/vless.link"

# SOCKS5 持久化文件
SOCKS_EN_FILE="${PERSIST_DIR}/socks_enable"
SOCKS_PORT_FILE="${PERSIST_DIR}/socks_port"
SOCKS_USER_FILE="${PERSIST_DIR}/socks_user"
SOCKS_PASS_FILE="${PERSIST_DIR}/socks_pass"
SOCKS_LINK_FILE="${PERSIST_DIR}/socks.link"

# XHTTP ENC Reality 持久化文件
REALITY_EN_FILE="${PERSIST_DIR}/reality_enable"
REALITY_PORT_FILE="${PERSIST_DIR}/reality_port"
REALITY_SNI_FILE="${PERSIST_DIR}/reality_sni"
REALITY_PRIV_FILE="${PERSIST_DIR}/reality_priv"
REALITY_PUB_FILE="${PERSIST_DIR}/reality_pub"
REALITY_SID_FILE="${PERSIST_DIR}/reality_sid"
REALITY_DEC_FILE="${PERSIST_DIR}/reality_dec"
REALITY_ENC_FILE="${PERSIST_DIR}/reality_enc"
REALITY_FLOW_FILE="${PERSIST_DIR}/reality_flow"
REALITY_LINK_FILE="${PERSIST_DIR}/reality.link"

# 精准检测活跃进程（彻底排除 Z 状态的 <defunct> 僵尸进程干扰）
is_alive() {
    ps -eo stat,comm 2>/dev/null | awk -v p="$1" '$1 !~ /Z/ && $2 == p {found=1} END {exit !found}'
}

# 生成 VLESS Encryption 密钥对 (参数1: 外观模式 native/xorpub/random)
gen_vless_enc() {
    MODE_STYLE="${1:-xorpub}"
    ENC_RAW=$(/usr/local/bin/xray vlessenc 2>/dev/null || true)
    if [ -z "$ENC_RAW" ]; then
        return 1
    fi
    RAW_DEC=$(printf "\%s\n" "$ENC_RAW" | grep '"decryption":' | tail -n 1 | sed -E 's/.*"decryption":[[:space:]]*"([^"]+)".*/\1/')
    RAW_ENC=$(printf "\%s\n" "$ENC_RAW" | grep '"encryption":' | tail -n 1 | sed -E 's/.*"encryption":[[:space:]]*"([^"]+)".*/\1/')
    if [ -z "$RAW_DEC" ] \vert{}\vert{} [ -z "$RAW_ENC" ]; then
        return 1
    fi
    GEN_DEC=$(printf "%s" "$RAW_DEC" \vert{} sed -E "s/^([^.]+)\.[^.]+\./\1.${MODE_STYLE}./")
    GEN_ENC=$(printf "%s" "$RAW_ENC" \vert{} sed -E "s/^([^.]+)\.[^.]+\./\1.${MODE_STYLE}./")
    return 0
}

# 获取本机公网 IP（优先 IPv4，无 IPv4 时自动回退 IPv6 并加括号）
get_public_ip() {
    PUB_IP=$(curl -s4m 5 https://api.ipify.org 2>/dev/null || curl -s4m 5 https://ifconfig.me 2>/dev/null || true)
    if [ -z "$PUB_IP" ]; then
        PUB_IP=$(curl -s6m 5 https://api64.ipify.org 2>/dev/null || true)
        [ -n "$PUB_IP" ] && PUB_IP="[${PUB_IP}]"
    fi
    [ -z "$PUB_IP" ] && PUB_IP="YOUR_SERVER_IP"
    printf "%s" "$PUB_IP"
}

echo "=================================================="
echo "   argo-xhttp-Pure (Argo + SOCKS5[v4] + Reality[v4/v6])"
echo "   内存固化: Xray(35MiB) / Cloudflare(30MiB) 无切片版"
echo "=================================================="

echo "=== 1. 检查系统环境与架构 ==="
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) XRAY_ARCH="64"; CF_ARCH="amd64" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a"; CF_ARCH="arm64" ;;
    armv7l|armv7) XRAY_ARCH="arm32-v7a"; CF_ARCH="arm" ;;
    i386|i686) XRAY_ARCH="32"; CF_ARCH="386" ;;
    s390x) XRAY_ARCH="s390x"; CF_ARCH="s390x" ;;
    *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
esac

if command -v apk >/dev/null 2>&1; then
    OS="alpine"
    apk update && apk add --no-cache curl unzip ca-certificates openssl grep sed psmisc procps
elif command -v apt-get >/dev/null 2>&1; then
    OS="debian"
    apt-get update && apt-get install -y curl unzip ca-certificates openssl grep sed psmisc procps
elif command -v dnf >/dev/null 2>&1; then
    OS="rhel"
    dnf install -y curl unzip ca-certificates openssl grep sed psmisc procps-ng
elif command -v yum >/dev/null 2>&1; then
    OS="rhel"
    yum install -y curl unzip ca-certificates openssl grep sed psmisc procps-ng
else
    echo "❌ 不支持的系统环境，缺少包管理器 (apk/apt/dnf/yum)"; exit 1
fi

echo "=== 2. 检查并开启 256MB Swap 虚拟内存（防 OOM）==="
SWAP_TOTAL=$(free -m 2>/dev/null | awk '/^Swap:/ {print $2}')
if [ "${SWAP_TOTAL:-0}" -eq 0 ]; then
    if [ ! -f /swapfile ]; then
        dd if=/dev/zero of=/swapfile bs=1M count=256 status=none 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=256 2>/dev/null || true
        if [ -f /swapfile ]; then
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1 || true
            if swapon /swapfile >/dev/null 2>&1; then
                grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
                echo "✅ 已开启 256MB Swap 兜底。"
            else
                rm -f /swapfile
                echo "ℹ️ 当前容器环境
