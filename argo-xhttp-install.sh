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
    RAW_DEC=$(printf "%s\n" "$ENC_RAW" | grep '"decryption":' | tail -n 1 | sed -E 's/.*"decryption":[[:space:]]*"([^"]+)".*/\1/')
    RAW_ENC=$(printf "%s\n" "$ENC_RAW" | grep '"encryption":' | tail -n 1 | sed -E 's/.*"encryption":[[:space:]]*"([^"]+)".*/\1/')
    if [ -z "$RAW_DEC" ] || [ -z "$RAW_ENC" ]; then
        return 1
    fi
    GEN_DEC=$(printf "%s" "$RAW_DEC" | sed -E "s/^([^.]+)\.[^.]+\./\1.${MODE_STYLE}./")
    GEN_ENC=$(printf "%s" "$RAW_ENC" | sed -E "s/^([^.]+)\.[^.]+\./\1.${MODE_STYLE}./")
    return 0
}

# 获取本机公网 IP（兼容 IPv4 / IPv6）
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
echo "   argo-xhttp-Pure (Argo + 可选 SOCKS5 / XHTTP-ENC-Reality)"
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
                echo "ℹ️ 当前容器环境限制挂载 Swap，已自动跳过（不影响运行）。"
            fi
        fi
    fi
fi

echo "=== 3. 检查并安装 Xray 与 cloudflared 二进制文件 ==="
if [ ! -f /usr/local/bin/xray ]; then
    LATEST_VER=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$LATEST_VER" ] && LATEST_VER="v26.3.27"
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VER}/Xray-linux-${XRAY_ARCH}.zip"
    mkdir -p /tmp/xray_argo /usr/local/bin
    curl -L "$XRAY_URL" -o /tmp/xray_argo/xray.zip
    unzip -o /tmp/xray_argo/xray.zip xray -d /usr/local/bin/
    chmod +x /usr/local/bin/xray
    rm -rf /tmp/xray_argo
fi

if [ ! -f /usr/local/bin/cloudflared ] && ! command -v cloudflared >/dev/null 2>&1; then
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    curl -L "$CF_URL" -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
fi
CF_BIN=$(command -v cloudflared || echo "/usr/local/bin/cloudflared")

echo ""
echo "=== 4. 读取或初始化固定配置 (/etc/argo-xhttp) ==="

if [ ! -s "$UUID_FILE" ] && [ -f "${XRAY_CONF_DIR}/config.json" ]; then
    OLD_UUID=$(grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "${XRAY_CONF_DIR}/config.json" | head -n 1 || true)
    [ -n "$OLD_UUID" ] && printf "%s" "$OLD_UUID" > "$UUID_FILE"
fi
if [ ! -s "$PATH_FILE" ] && [ -f "${XRAY_CONF_DIR}/config.json" ]; then
    OLD_PATH=$(grep '"path":' "${XRAY_CONF_DIR}/config.json" | sed -E 's/.*"path":[[:space:]]*"([^"]+)".*/\1/' | head -n 1 || true)
    [ -n "$OLD_PATH" ] && printf "%s" "$OLD_PATH" > "$PATH_FILE"
fi
if [ ! -s "$TOKEN_FILE" ]; then
    for f in "${XRAY_CONF_DIR}/argo_token.txt" /etc/systemd/system/cloudflared*.service /etc/init.d/cloudflared*; do
        if [ -f "$f" ]; then
            OLD_TOK=$(grep -oE 'eyJh[A-Za-z0-9_-]+' "$f" | head -n 1 || true)
            if [ -n "$OLD_TOK" ]; then
                printf "%s" "$OLD_TOK" > "$TOKEN_FILE"
                break
            fi
        fi
    done
fi
if [ ! -s "$DOMAIN_FILE" ] && [ -f "${XRAY_CONF_DIR}/argo_state.conf" ]; then
    OLD_DOM=$(grep 'SAVED_DOMAIN=' "${XRAY_CONF_DIR}/argo_state.conf" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)
    [ -n "$OLD_DOM" ] && printf "%s" "$OLD_DOM" > "$DOMAIN_FILE"
fi

SAVED_UUID=$(cat "$UUID_FILE" 2>/dev/null || true)
SAVED_PATH=$(cat "$PATH_FILE" 2>/dev/null || true)
SAVED_MODE=$(cat "$MODE_FILE" 2>/dev/null || true)
SAVED_ARGO_PORT=$(cat "$ARGO_PORT_FILE" 2>/dev/null || true)
SAVED_DOMAIN=$(cat "$DOMAIN_FILE" 2>/dev/null || true)
SAVED_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null || true)
SAVED_ADDR=$(cat "$ADDR_FILE" 2>/dev/null || true)
SAVED_DEC=$(cat "$DEC_FILE" 2>/dev/null || true)
SAVED_ENC=$(cat "$ENC_FILE" 2>/dev/null || true)
SAVED_FLOW=$(cat "$FLOW_FILE" 2>/dev/null || true)

SAVED_SOCKS_EN=$(cat "$SOCKS_EN_FILE" 2>/dev/null || true)
SAVED_SOCKS_PORT=$(cat "$SOCKS_PORT_FILE" 2>/dev/null || true)
SAVED_SOCKS_USER=$(cat "$SOCKS_USER_FILE" 2>/dev/null || true)
SAVED_SOCKS_PASS=$(cat "$SOCKS_PASS_FILE" 2>/dev/null || true)

SAVED_REALITY_EN=$(cat "$REALITY_EN_FILE" 2>/dev/null || true)
SAVED_REALITY_PORT=$(cat "$REALITY_PORT_FILE" 2>/dev/null || true)
SAVED_REALITY_SNI=$(cat "$REALITY_SNI_FILE" 2>/dev/null || true)
SAVED_REALITY_PRIV=$(cat "$REALITY_PRIV_FILE" 2>/dev/null || true)
SAVED_REALITY_PUB=$(cat "$REALITY_PUB_FILE" 2>/dev/null || true)
SAVED_REALITY_SID=$(cat "$REALITY_SID_FILE" 2>/dev/null || true)
SAVED_REALITY_DEC=$(cat "$REALITY_DEC_FILE" 2>/dev/null || true)
SAVED_REALITY_ENC=$(cat "$REALITY_ENC_FILE" 2>/dev/null || true)

# ---------------- 4.1 UUID 与 Path (Argo 与 Reality 共用) ----------------
if [ -n "$SAVED_UUID" ] && [ -n "$SAVED_PATH" ]; then
    echo "✅ 已锁定固定 UUID 与 Path (Argo 与 Reality 共用)："
    echo "   UUID : ${SAVED_UUID}"
    echo "   Path : ${SAVED_PATH}"
    printf "直接回车沿用，或输入 n 重新随机生成 [Y/n]: "
    read -r NEW_ID_CHOICE < /dev/tty
    if [ "$NEW_ID_CHOICE" = "n" ] || [ "$NEW_ID_CHOICE" = "N" ]; then
        UUID=$(/usr/local/bin/xray uuid)
        XHTTP_PATH="/$(openssl rand -hex 6)"
        printf "%s" "$UUID" > "$UUID_FILE"
        printf "%s" "$XHTTP_PATH" > "$PATH_FILE"
        echo "🔄 已生成并写入新 UUID 与 Path。"
    else
        UUID="$SAVED_UUID"
        XHTTP_PATH="$SAVED_PATH"
    fi
else
    UUID=$(/usr/local/bin/xray uuid)
    XHTTP_PATH="/$(openssl rand -hex 6)"
    printf "%s" "$UUID" > "$UUID_FILE"
    printf "%s" "$XHTTP_PATH" > "$PATH_FILE"
    echo "✅ 已首次生成并固定写入 UUID 与 Path。"
fi
RAND_STR=$(echo "$XHTTP_PATH" | sed 's/^\///')
ENCODED_PATH="%2F${RAND_STR}"

# ---------------- 4.2 Argo 本地回环端口与隧道模式 ----------------
DEF_ARGO_PORT="${SAVED_ARGO_PORT:-8080}"
echo ""
printf "请输入 Argo 本地回环端口 (直接回车默认 [${DEF_ARGO_PORT}]): "
read -r IN_ARGO_PORT < /dev/tty
ARGO_PORT="${IN_ARGO_PORT:-$DEF_ARGO_PORT}"
printf "%s" "$ARGO_PORT" > "$ARGO_PORT_FILE"

DEFAULT_MODE="${SAVED_MODE:-1}"
echo ""
echo "请选择 Cloudflare Argo 隧道模式："
echo "  [1] 固定隧道 (绑定自有域名，支持 Token 或 fscarmen JSON)"
echo "  [2] 临时隧道 (免账号免域名，自动申请 trycloudflare.com 临时域名)"
printf "请输入序号 [1-2] (直接回车沿用默认 [${DEFAULT_MODE}]): "
read -r INPUT_MODE < /dev/tty
TUNNEL_MODE="${INPUT_MODE:-$DEFAULT_MODE}"
printf "%s" "$TUNNEL_MODE" > "$MODE_FILE"

# ---------------- 4.3 固定隧道域名与 Token ----------------
if [ "$TUNNEL_MODE" = "1" ]; then
    if [ -n "$SAVED_DOMAIN" ]; then
        echo "✅ 已锁定固定隧道域名: ${SAVED_DOMAIN}"
        printf "直接回车沿用 [${SAVED_DOMAIN}]，或输入新域名覆盖: "
        read -r INPUT_DOMAIN < /dev/tty
        if [ -n "$INPUT_DOMAIN" ]; then
            CF_DOMAIN="$INPUT_DOMAIN"
            printf "%s" "$CF_DOMAIN" > "$DOMAIN_FILE"
        else
            CF_DOMAIN="$SAVED_DOMAIN"
        fi
    else
        while [ -z "$CF_DOMAIN" ]; do
            printf "请输入 Argo 固定隧道域名 (例如 tunnel.example.com): "
            read -r CF_DOMAIN < /dev/tty
        done
        printf "%s" "$CF_DOMAIN" > "$DOMAIN_FILE"
    fi

    if [ -n "$SAVED_TOKEN" ]; then
        TOK_PREVIEW=$(echo "$SAVED_TOKEN" | cut -c 1-28)
        echo "✅ 已锁定隧道凭证 (Token/JSON): ${TOK_PREVIEW}..."
        printf "直接回车沿用现有凭证，或粘贴新 Token / JSON 覆盖: "
        read -r INPUT_TOKEN < /dev/tty
        if [ -n "$INPUT_TOKEN" ]; then
            CF_TOKEN="$INPUT_TOKEN"
            printf "%s" "$CF_TOKEN" > "$TOKEN_FILE"
        else
            CF_TOKEN="$SAVED_TOKEN"
        fi
    else
        while [ -z "$CF_TOKEN" ]; do
            printf "请输入 Argo 隧道 Token (eyJh...) 或 fscarmen 生成的 JSON: "
            read -r CF_TOKEN < /dev/tty
        done
        printf "%s" "$CF_TOKEN" > "$TOKEN_FILE"
    fi

    if echo "$CF_TOKEN" | grep -q '{'; then
        printf "%s" "$CF_TOKEN" > "${PERSIST_DIR}/tunnel.json"
        TUNNEL_ID=$(echo "$CF_TOKEN" | grep -oE '"TunnelID":[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"/\1/')
        cat << YAML > "${PERSIST_DIR}/config.yml"
tunnel: ${TUNNEL_ID}
credentials-file: ${PERSIST_DIR}/tunnel.json
protocol: http2
ingress:
  - hostname: ${CF_DOMAIN}
    service: http://127.0.0.1:${ARGO_PORT}
  - service: http_status:404
YAML
        CF_RUN_ARGS="tunnel --no-autoupdate --protocol http2 --ha-connections 1 --config ${PERSIST_DIR}/config.yml run"
    else
        rm -f "${PERSIST_DIR}/config.yml" "${PERSIST_DIR}/tunnel.json"
        CF_RUN_ARGS="tunnel --no-autoupdate --protocol http2 --ha-connections 1 run --token ${CF_TOKEN}"
    fi
else
    echo "⚡ 已选择【临时隧道】..."
    rm -f /var/log/cloudflared.log "${PERSIST_DIR}/config.yml" "${PERSIST_DIR}/tunnel.json"
    CF_RUN_ARGS="tunnel --no-autoupdate --protocol http2 --ha-connections 1 --url http://127.0.0.1:${ARGO_PORT} --logfile /var/log/cloudflared.log"
fi

# ---------------- 4.4 优选域名读取与写入 ----------------
echo ""
echo "请选择优选域名 / 客户端连接地址："
echo "  [0] 不优选，直接使用隧道域名本身"
echo "  [1] cloudflare.182682.xyz (推荐)"
echo "  [2] cf.090227.xyz"
echo "  [3] saas.sin.fan"
echo "  [4] cf.0sm.com"
echo "  [5] freeyx.cloudflare88.eu.org"
echo "  [6] 手动输入自定义优选域名或 IP"
printf "请输入序号 [0-6] (回车默认 [1]): "
read -r OPT_CHOICE < /dev/tty

case "$OPT_CHOICE" in
    0) ADDR="" ;;
    1) ADDR="cloudflare.182682.xyz" ;;
    2) ADDR="cf.090227.xyz" ;;
    3) ADDR="saas.sin.fan" ;;
    4) ADDR="cf.0sm.com" ;;
    5) ADDR="freeyx.cloudflare88.eu.org" ;;
    6)
        printf "请输入自定义优选域名或 IP: "
        read -r CUSTOM_ADDR < /dev/tty
        ADDR="$CUSTOM_ADDR"
        ;;
    *)
        ADDR="${SAVED_ADDR:-cloudflare.182682.xyz}"
        ;;
esac
printf "%s" "$ADDR" > "$ADDR_FILE"

# ---------------- 4.5 Argo VLESS Encryption 与 Flow (可选并持久化) ----------------
echo ""
echo "=== 4.5 Argo VLESS Encryption (enc) 与 Flow 配置 ==="
XRAY_DECRYPTION="none"
XRAY_ENCRYPTION="none"
NEED_GEN_ENC="0"

if [ -n "$SAVED_DEC" ] && [ -n "$SAVED_ENC" ] && [ "$SAVED_DEC" != "none" ]; then
    DEC_PREVIEW=$(printf "%s" "$SAVED_DEC" | cut -c 1-36)
    echo "✅ 已锁定 VLESS Encryption: ${DEC_PREVIEW}..."
    echo "  [1] 保留当前加密方式 (默认)"
    echo "  [2] 重新生成新的 VLESS Encryption 密钥"
    echo "  [3] 关闭 VLESS Encryption (恢复为 none)"
    printf "请选择 [1-3] (直接回车保留当前): "
    read -r ENC_ACTION < /dev/tty
    case "$ENC_ACTION" in
        2) NEED_GEN_ENC="1" ;;
        3)
            XRAY_DECRYPTION="none"
            XRAY_ENCRYPTION="none"
            echo "🔄 已关闭 VLESS Encryption。"
            ;;
        *)
            XRAY_DECRYPTION="$SAVED_DEC"
            XRAY_ENCRYPTION="$SAVED_ENC"
            echo "✅ 已沿用现有 VLESS Encryption。"
            ;;
    esac
else
    echo "当前未启用 VLESS Encryption (none)。是否开启？"
    echo "  [1] 关闭 (none，默认)"
    echo "  [2] 开启 VLESS Encryption (支持 xorpub / native / random)"
    printf "请选择 [1-2] (回车默认 [1]): "
    read -r ENC_ENABLE_CHOICE < /dev/tty
    if [ "$ENC_ENABLE_CHOICE" = "2" ]; then
        NEED_GEN_ENC="1"
    fi
fi

if [ "$NEED_GEN_ENC" = "1" ]; then
    echo "请选择 VLESS Encryption 流量外观模式："
    echo "  [1] xorpub (推荐，混淆握手公钥)"
    echo "  [2] native (原始格式)"
    echo "  [3] random (全随机外观)"
    printf "请选择 [1-3] (回车默认 [1]): "
    read -r ENC_STYLE_CHOICE < /dev/tty
    case "$ENC_STYLE_CHOICE" in
        2) ENC_STYLE="native" ;;
        3) ENC_STYLE="random" ;;
        *) ENC_STYLE="xorpub" ;;
    esac

    if gen_vless_enc "$ENC_STYLE"; then
        XRAY_DECRYPTION="$GEN_DEC"
        XRAY_ENCRYPTION="$GEN_ENC"
        echo "✅ 已生成 VLESS Encryption (${ENC_STYLE}) 并写入持久化文件。"
    else
        echo "⚠️ 当前 Xray 版本不支持 xray vlessenc，已自动回退为 none。"
        XRAY_DECRYPTION="none"
        XRAY_ENCRYPTION="none"
    fi
fi

printf "%s" "$XRAY_DECRYPTION" > "$DEC_FILE"
printf "%s" "$XRAY_ENCRYPTION" > "$ENC_FILE"

if [ "$XRAY_DECRYPTION" != "none" ]; then
    if [ -n "$SAVED_FLOW" ]; then
        echo "✅ 已锁定 Flow 流控: ${SAVED_FLOW}"
        printf "直接回车沿用 [${SAVED_FLOW}]，或输入 n 关闭 Flow [Y/n]: "
        read -r FLOW_KEEP < /dev/tty
        if [ "$FLOW_KEEP" = "n" ] || [ "$FLOW_KEEP" = "N" ]; then
            XRAY_FLOW=""
        else
            XRAY_FLOW="$SAVED_FLOW"
        fi
    else
        echo "是否开启 Flow 流控 (xtls-rprx-vision)？"
        echo "  [1] 不开启 (留空，默认)"
        echo "  [2] 开启 xtls-rprx-vision"
        printf "请选择 [1-2] (回车默认 [1]): "
        read -r FLOW_CHOICE < /dev/tty
        if [ "$FLOW_CHOICE" = "2" ]; then
            XRAY_FLOW="xtls-rprx-vision"
        else
            XRAY_FLOW=""
        fi
    fi
else
    XRAY_FLOW=""
fi
printf "%s" "$XRAY_FLOW" > "$FLOW_FILE"

if [ -n "$XRAY_FLOW" ]; then
    CLIENT_JSON="          {
            \"id\": \"${UUID}\",
            \"flow\": \"${XRAY_FLOW}\"
          }"
    FLOW_PARAM="&flow=${XRAY_FLOW}"
else
    CLIENT_JSON="          {
            \"id\": \"${UUID}\"
          }"
    FLOW_PARAM=""
fi

# ---------------- 4.6 可选：SOCKS5 代理入站（手动设置端口与账号密码） ----------------
echo ""
echo "=== 4.6 可选：SOCKS5 代理入站配置 ==="
DEFAULT_SOCKS_EN="${SAVED_SOCKS_EN:-0}"
if [ "$DEFAULT_SOCKS_EN" = "1" ]; then
    echo "当前已启用 SOCKS5 (端口: ${SAVED_SOCKS_PORT}，用户: ${SAVED_SOCKS_USER})"
    printf "是否继续启用 SOCKS5？[Y/n] (直接回车保持启用): "
    read -r SOCKS_CHOICE < /dev/tty
    if [ "$SOCKS_CHOICE" = "n" ] || [ "$SOCKS_CHOICE" = "N" ]; then
        SOCKS_ENABLE="0"
    else
        SOCKS_ENABLE="1"
    fi
else
    printf "是否开启 SOCKS5 入站代理？[y/N] (直接回车关闭): "
    read -r SOCKS_CHOICE < /dev/tty
    if [ "$SOCKS_CHOICE" = "y" ] || [ "$SOCKS_CHOICE" = "Y" ]; then
        SOCKS_ENABLE="1"
    else
        SOCKS_ENABLE="0"
    fi
fi
printf "%s" "$SOCKS_ENABLE" > "$SOCKS_EN_FILE"

if [ "$SOCKS_ENABLE" = "1" ]; then
    if [ -n "$SAVED_SOCKS_PORT" ]; then
        printf "请输入 SOCKS5 监听端口 (直接回车沿用 [${SAVED_SOCKS_PORT}]): "
        read -r IN_S_PORT < /dev/tty
        SOCKS_PORT="${IN_S_PORT:-$SAVED_SOCKS_PORT}"
    else
        SOCKS_PORT=""
        while [ -z "$SOCKS_PORT" ]; do
            printf "请手动输入 SOCKS5 监听端口 (例如 10808): "
            read -r SOCKS_PORT < /dev/tty
        done
    fi

    if [ -n "$SAVED_SOCKS_USER" ]; then
        printf "请输入 SOCKS5 用户名 (直接回车沿用 [${SAVED_SOCKS_USER}]): "
        read -r IN_S_USER < /dev/tty
        SOCKS_USER="${IN_S_USER:-$SAVED_SOCKS_USER}"
    else
        SOCKS_USER=""
        while [ -z "$SOCKS_USER" ]; do
            printf "请手动输入 SOCKS5 用户名: "
            read -r SOCKS_USER < /dev/tty
        done
    fi

    if [ -n "$SAVED_SOCKS_PASS" ]; then
        printf "请输入 SOCKS5 密码 (直接回车沿用已保存密码): "
        read -r IN_S_PASS < /dev/tty
        SOCKS_PASS="${IN_S_PASS:-$SAVED_SOCKS_PASS}"
    else
        SOCKS_PASS=""
        while [ -z "$SOCKS_PASS" ]; do
            printf "请手动输入 SOCKS5 密码: "
            read -r SOCKS_PASS < /dev/tty
        done
    fi

    printf "%s" "$SOCKS_PORT" > "$SOCKS_PORT_FILE"
    printf "%s" "$SOCKS_USER" > "$SOCKS_USER_FILE"
    printf "%s" "$SOCKS_PASS" > "$SOCKS_PASS_FILE"
    echo "✅ 已配置 SOCKS5 入站: 端口 ${SOCKS_PORT} / 用户 ${SOCKS_USER}"
fi

# ---------------- 4.7 可选：XHTTP + ENC + Reality 直连入站（独立 stream-one，共用 UUID 与 Path） ----------------
echo ""
echo "=== 4.7 可选：XHTTP + ENC + Reality 直连入站配置 ==="
DEFAULT_REALITY_EN="${SAVED_REALITY_EN:-0}"
if [ "$DEFAULT_REALITY_EN" = "1" ]; then
    echo "当前已启用 XHTTP-ENC-Reality (端口: ${SAVED_REALITY_PORT:-8443}，SNI: ${SAVED_REALITY_SNI:-www.microsoft.com})"
    printf "是否继续启用 XHTTP-ENC-Reality？[Y/n] (直接回车保持启用): "
    read -r REALITY_CHOICE < /dev/tty
    if [ "$REALITY_CHOICE" = "n" ] || [ "$REALITY_CHOICE" = "N" ]; then
        REALITY_ENABLE="0"
    else
        REALITY_ENABLE="1"
    fi
else
    printf "是否开启 XHTTP + ENC + Reality 直连节点 (与 Argo 共用 UUID/Path)？[y/N] (直接回车关闭): "
    read -r REALITY_CHOICE < /dev/tty
    if [ "$REALITY_CHOICE" = "y" ] || [ "$REALITY_CHOICE" = "Y" ]; then
        REALITY_ENABLE="1"
    else
        REALITY_ENABLE="0"
    fi
fi
printf "%s" "$REALITY_ENABLE" > "$REALITY_EN_FILE"

if [ "$REALITY_ENABLE" = "1" ]; then
    DEF_R_PORT="${SAVED_REALITY_PORT:-8443}"
    printf "请输入 Reality 监听端口 (直接回车默认 [${DEF_R_PORT}]): "
    read -r IN_R_PORT < /dev/tty
    REALITY_PORT="${IN_R_PORT:-$DEF_R_PORT}"

    DEF_R_SNI="${SAVED_REALITY_SNI:-www.microsoft.com}"
    printf "请输入 Reality 伪装域名 SNI (直接回车默认 [${DEF_R_SNI}]): "
    read -r IN_R_SNI < /dev/tty
    REALITY_SNI="${IN_R_SNI:-$DEF_R_SNI}"

    if [ -n "$SAVED_REALITY_PRIV" ] && [ -n "$SAVED_REALITY_PUB" ] && [ -n "$SAVED_REALITY_SID" ]; then
        REALITY_PRIV="$SAVED_REALITY_PRIV"
        REALITY_PUB="$SAVED_REALITY_PUB"
        REALITY_SID="$SAVED_REALITY_SID"
        echo "✅ 已沿用现有 Reality 密钥对与 ShortID。"
    else
        X25519_RAW=$(/usr/local/bin/xray x25519 2>/dev/null || true)
        REALITY_PRIV=$(printf "%s\n" "$X25519_RAW" | awk -F': ' '/Private/ {print $2; exit}' | tr -d ' \r\n')
        REALITY_PUB=$(printf "%s\n" "$X25519_RAW" | awk -F': ' '/Public|Password/ {print $2; exit}' | tr -d ' \r\n')
        REALITY_SID=$(openssl rand -hex 4)
        echo "✅ 已生成新的 Reality x25519 密钥对与 ShortID。"
    fi

    if [ -n "$SAVED_REALITY_DEC" ] && [ -n "$SAVED_REALITY_ENC" ] && [ "$SAVED_REALITY_DEC" != "none" ]; then
        REALITY_DEC="$SAVED_REALITY_DEC"
        REALITY_ENC="$SAVED_REALITY_ENC"
        echo "✅ 已沿用现有 Reality VLESS Encryption。"
    else
        echo "请选择 Reality 节点的 VLESS Encryption 模式："
        echo "  [1] xorpub (推荐，默认开启 ENC)"
        echo "  [2] native"
        echo "  [3] random"
        echo "  [4] none (不开启 ENC，仅纯 Reality)"
        printf "请选择 [1-4] (回车默认 [1]): "
        read -r R_ENC_CHOICE < /dev/tty
        case "$R_ENC_CHOICE" in
            4)
                REALITY_DEC="none"
                REALITY_ENC="none"
                ;;
            2) R_STYLE="native" ;;
            3) R_STYLE="random" ;;
            *) R_STYLE="xorpub" ;;
        esac
        if [ "$R_ENC_CHOICE" != "4" ]; then
            if gen_vless_enc "$R_STYLE"; then
                REALITY_DEC="$GEN_DEC"
                REALITY_ENC="$GEN_ENC"
                echo "✅ 已生成 Reality VLESS Encryption (${R_STYLE})。"
            else
                echo "⚠️ 当前 Xray 版本不支持 xray vlessenc，Reality ENC 已回退为 none。"
                REALITY_DEC="none"
                REALITY_ENC="none"
            fi
        fi
    fi

    printf "%s" "$REALITY_PORT" > "$REALITY_PORT_FILE"
    printf "%s" "$REALITY_SNI" > "$REALITY_SNI_FILE"
    printf "%s" "$REALITY_PRIV" > "$REALITY_PRIV_FILE"
    printf "%s" "$REALITY_PUB" > "$REALITY_PUB_FILE"
    printf "%s" "$REALITY_SID" > "$REALITY_SID_FILE"
    printf "%s" "$REALITY_DEC" > "$REALITY_DEC_FILE"
    printf "%s" "$REALITY_ENC" > "$REALITY_ENC_FILE"
fi

echo ""
echo "=== 5. 写入优化后的 Xray 配置 (Argo: packet-up / Reality: stream-one) ==="

EXTRA_INBOUNDS=""

if [ "$SOCKS_ENABLE" = "1" ]; then
    EXTRA_INBOUNDS="${EXTRA_INBOUNDS},
    {
      \"tag\": \"socks-in\",
      \"listen\": \"0.0.0.0\",
      \"port\": ${SOCKS_PORT},
      \"protocol\": \"socks\",
      \"settings\": {
        \"auth\": \"password\",
        \"accounts\": [
          {
            \"user\": \"${SOCKS_USER}\",
            \"pass\": \"${SOCKS_PASS}\"
          }
        ],
        \"udp\": true
      }
    }"
fi

if [ "$REALITY_ENABLE" = "1" ]; then
    EXTRA_INBOUNDS="${EXTRA_INBOUNDS},
    {
      \"tag\": \"xhttp-reality-in\",
      \"listen\": \"0.0.0.0\",
      \"port\": ${REALITY_PORT},
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [
          {
            \"id\": \"${UUID}\"
          }
        ],
        \"decryption\": \"${REALITY_DEC}\"
      },
      \"streamSettings\": {
        \"network\": \"xhttp\",
        \"xhttpSettings\": {
          \"path\": \"${XHTTP_PATH}\",
          \"mode\": \"stream-one\"
        },
        \"security\": \"reality\",
        \"realitySettings\": {
          \"show\": false,
          \"dest\": \"${REALITY_SNI}:443\",
          \"xver\": 0,
          \"serverNames\": [
            \"${REALITY_SNI}\"
          ],
          \"privateKey\": \"${REALITY_PRIV}\",
          \"shortIds\": [
            \"${REALITY_SID}\"
          ]
        }
      }
    }"
fi

cat << JSON > "${XRAY_CONF_DIR}/config.json"
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "argo-xhttp-in",
      "listen": "127.0.0.1",
      "port": ${ARGO_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
${CLIENT_JSON}
        ],
        "decryption": "${XRAY_DECRYPTION}"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "packet-up"
        },
        "security": "none",
        "sockopt": {
          "trustedXForwardedFor": [
            "CF-Connecting-IP",
            "X-Forwarded-For"
          ]
        }
      }
    }${EXTRA_INBOUNDS}
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "ip": [
          "127.0.0.0/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "::1/128",
          "fc00::/7"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
JSON

echo "=== 6. 彻底物理清场旧进程并启动服务 (35M/30M + GOGC=20) ==="

if command -v rc-service >/dev/null 2>&1; then
    mkdir -p /run/openrc
    touch /run/openrc/softlevel
    rc-service cloudflared stop >/dev/null 2>&1 || true
    rc-service xray stop >/dev/null 2>&1 || true
    rc-service cloudflared zap >/dev/null 2>&1 || true
    rc-service xray zap >/dev/null 2>&1 || true
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop cloudflared xray >/dev/null 2>&1 || true
fi
killall -9 cloudflared xray >/dev/null 2>&1 || true
rm -f /run/xray.pid /run/cloudflared.pid /run/openrc/started/xray /run/openrc/started/cloudflared

if [ "$OS" = "alpine" ] && command -v rc-service >/dev/null 2>&1; then
    mkdir -p /run/openrc
    touch /run/openrc/softlevel

    cat << 'OPENRC_XRAY' > /etc/init.d/xray
#!/sbin/openrc-run
name="xray"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"
rc_ulimit="-n 65535"

export GOMEMLIMIT=35MiB
export GOGC=20

depend() { need net; }

stop_pre() {
    killall -9 xray >/dev/null 2>&1 || true
    rm -f /run/xray.pid
}
OPENRC_XRAY
    chmod +x /etc/init.d/xray

    cat << OPENRC_CF > /etc/init.d/cloudflared
#!/sbin/openrc-run
name="cloudflared"
command="${CF_BIN}"
command_args="${CF_RUN_ARGS}"
command_background="yes"
pidfile="/run/cloudflared.pid"
rc_ulimit="-n 65535"

export GOMEMLIMIT=30MiB
export GOGC=20

depend() { need net; }

stop_pre() {
    killall -9 cloudflared >/dev/null 2>&1 || true
    rm -f /run/cloudflared.pid
}
OPENRC_CF
    chmod +x /etc/init.d/cloudflared

    rc-update add xray default >/dev/null 2>&1 || true
    rc-update add cloudflared default >/dev/null 2>&1 || true
    rc-service xray start >/dev/null 2>&1 || true
    sleep 1
    rc-service cloudflared start >/dev/null 2>&1 || true

elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    cat << 'SYS_XRAY' > /etc/systemd/system/xray.service
[Unit]
Description=Xray Local & Direct Service
After=network.target

[Service]
Type=simple
LimitNOFILE=65535
Environment="GOMEMLIMIT=35MiB"
Environment="GOGC=20"
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
SYS_XRAY

    cat << SYS_CF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Argo Tunnel (Lite Single-Connection)
After=network.target

[Service]
Type=simple
LimitNOFILE=65535
Environment="GOMEMLIMIT=30MiB"
Environment="GOGC=20"
ExecStart=${CF_BIN} ${CF_RUN_ARGS}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SYS_CF

    systemctl daemon-reload
    systemctl enable xray cloudflared >/dev/null 2>&1 || true
    systemctl start xray >/dev/null 2>&1 || true
    sleep 1
    systemctl start cloudflared >/dev/null 2>&1 || true
fi

sleep 2
if ! is_alive "xray"; then
    GOMEMLIMIT=35MiB GOGC=20 nohup /usr/local/bin/xray run -c "${XRAY_CONF_DIR}/config.json" >/dev/null 2>&1 &
fi
if ! is_alive "cloudflared"; then
    GOMEMLIMIT=30MiB GOGC=20 nohup ${CF_BIN} ${CF_RUN_ARGS} >/dev/null 2>&1 &
fi

sleep 2
if is_alive "xray" && is_alive "cloudflared"; then
    echo "✅ Xray 与 cloudflared 均已成功启动并运行！"
else
    echo "⚠️ 警告：部分进程未能正常启动，请执行 ps aux 检查！"
fi

if [ "$TUNNEL_MODE" = "2" ]; then
    echo "⏳ 正在等待 Cloudflare 分配临时隧道域名 (约 3~8 秒)..."
    CF_DOMAIN=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 1
        if [ -f /var/log/cloudflared.log ]; then
            CF_DOMAIN=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' /var/log/cloudflared.log | head -n 1 | sed 's/https:\/\///' || true)
            [ -n "$CF_DOMAIN" ] && break
        fi
    done
    [ -z "$CF_DOMAIN" ] && CF_DOMAIN="请检查 /var/log/cloudflared.log 获取临时域名"
fi

FINAL_ADDR="${ADDR:-$CF_DOMAIN}"
EXTRA_PARAM="&extra=%7B%22xmux%22%3A%7B%22maxConcurrency%22%3A%224-8%22%2C%22cMaxReuseTimes%22%3A%2232-64%22%7D%7D"
VLESS_LINK="vless://${UUID}@${FINAL_ADDR}:443?encryption=${XRAY_ENCRYPTION}${FLOW_PARAM}&security=tls&sni=${CF_DOMAIN}&fp=chrome&alpn=h2&type=xhttp&host=${CF_DOMAIN}&path=${ENCODED_PATH}&mode=packet-up${EXTRA_PARAM}#Argo-XHTTP-${CF_DOMAIN}"
printf "%s\n" "$VLESS_LINK" > "$LINK_FILE"

SERVER_IP=""
if [ "$SOCKS_ENABLE" = "1" ] || [ "$REALITY_ENABLE" = "1" ]; then
    SERVER_IP=$(get_public_ip)
fi

if [ "$SOCKS_ENABLE" = "1" ]; then
    SOCKS_AUTH_B64=$(printf "%s:%s" "$SOCKS_USER" "$SOCKS_PASS" | openssl base64 -A)
    SOCKS_LINK="socks://${SOCKS_AUTH_B64}@${SERVER_IP}:${SOCKS_PORT}#SOCKS5-${SOCKS_PORT}"
    printf "%s\n" "$SOCKS_LINK" > "$SOCKS_LINK_FILE"
else
    rm -f "$SOCKS_LINK_FILE"
fi

if [ "$REALITY_ENABLE" = "1" ]; then
    REALITY_LINK="vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=${REALITY_ENC}&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=xhttp&path=${ENCODED_PATH}&mode=stream-one${EXTRA_PARAM}#Reality-XHTTP-${REALITY_PORT}"
    printf "%s\n" "$REALITY_LINK" > "$REALITY_LINK_FILE"
else
    rm -f "$REALITY_LINK_FILE"
fi

ENC_STATUS="none"
[ "$XRAY_DECRYPTION" != "none" ] && ENC_STATUS="$(printf "%s" "$XRAY_DECRYPTION" | cut -c 1-36)..."

echo ""
echo "=================================================="
echo "✅ argo-xhttp-Pure (无切片满血版) 部署完成！"
echo "=================================================="
echo "固定配置目录     : /etc/argo-xhttp/"
echo "内存与GC策略     : Xray(35M) / Cloudflare(30M), GOGC=20"
echo "共用 UUID        : ${UUID}"
echo "共用 Path        : ${XHTTP_PATH}"
echo "--------------------------------------------------"
echo "【1. Argo XHTTP 节点 (packet-up)】"
echo "本地回环端口     : 127.0.0.1:${ARGO_PORT}"
echo "隧道域名 (SNI)   : ${CF_DOMAIN}"
echo "连接地址 (优选)  : ${FINAL_ADDR}"
echo "Encryption (enc) : ${ENC_STATUS}"
echo "Flow (流控)      : ${XRAY_FLOW:-none}"
echo ""
echo "${VLESS_LINK}"

if [ "$SOCKS_ENABLE" = "1" ]; then
    echo "--------------------------------------------------"
    echo "【2. SOCKS5 节点】 (请确保防火墙放行 TCP/UDP ${SOCKS_PORT})"
    echo "地址:端口        : ${SERVER_IP}:${SOCKS_PORT}"
    echo "用户名 / 密码    : ${SOCKS_USER} / ${SOCKS_PASS}"
    echo ""
    echo "${SOCKS_LINK}"
fi

if [ "$REALITY_ENABLE" = "1" ]; then
    R_ENC_STATUS="none"
    [ "$REALITY_DEC" != "none" ] && R_ENC_STATUS="$(printf "%s" "$REALITY_DEC" | cut -c 1-36)..."
    echo "--------------------------------------------------"
    echo "【3. XHTTP + ENC + Reality 直连节点 (stream-one)】 (请确保防火墙放行 TCP ${REALITY_PORT})"
    echo "地址:端口        : ${SERVER_IP}:${REALITY_PORT}"
    echo "SNI              : ${REALITY_SNI}"
    echo "Public Key / SID : ${REALITY_PUB} / ${REALITY_SID}"
    echo "Encryption (enc) : ${R_ENC_STATUS}"
    echo ""
    echo "${REALITY_LINK}"
fi

echo "=================================================="
echo "💡 查看所有节点链接命令: cat /etc/argo-xhttp/*.link"
echo "=================================================="
