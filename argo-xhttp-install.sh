#!/bin/sh

# 固定持久化配置目录（所有参数独立文件存储，永不丢失）
PERSIST_DIR="/etc/argo-xhttp"
XRAY_CONF_DIR="/usr/local/etc/xray"
mkdir -p "$PERSIST_DIR" "$XRAY_CONF_DIR"
chmod 700 "$PERSIST_DIR"

UUID_FILE="${PERSIST_DIR}/uuid"
PATH_FILE="${PERSIST_DIR}/path"
MODE_FILE="${PERSIST_DIR}/mode"
DOMAIN_FILE="${PERSIST_DIR}/domain"
TOKEN_FILE="${PERSIST_DIR}/token"
ADDR_FILE="${PERSIST_DIR}/addr"
LINK_FILE="${PERSIST_DIR}/vless.link"

# 精准检测活跃进程（彻底排除 Z 状态的 <defunct> 僵尸进程干扰）
is_alive() {
    ps -eo stat,comm 2>/dev/null | awk -v p="$1" '$1 !~ /Z/ && $2 == p {found=1} END {exit !found}'
}

echo "=================================================="
echo "   argo-xhttp-Pure (VLESS+XHTTP + Cloudflare Argo)"
echo "   内存固化: Xray(45MiB) / Cloudflare(45MiB) + 128K切片"
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
SAVED_DOMAIN=$(cat "$DOMAIN_FILE" 2>/dev/null || true)
SAVED_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null || true)
SAVED_ADDR=$(cat "$ADDR_FILE" 2>/dev/null || true)

# ---------------- 4.1 UUID 与 Path ----------------
if [ -n "$SAVED_UUID" ] && [ -n "$SAVED_PATH" ]; then
    echo "✅ 已锁定固定 UUID 与 Path："
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

# ---------------- 4.2 隧道模式 ----------------
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
    service: http://127.0.0.1:8080
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
    CF_RUN_ARGS="tunnel --no-autoupdate --protocol http2 --ha-connections 1 --url http://127.0.0.1:8080 --logfile /var/log/cloudflared.log"
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

echo "=== 5. 写入优化后的 Xray 本地回环配置 (集成 128KB 切片与静默过滤) ==="
cat << JSON > "${XRAY_CONF_DIR}/config.json"
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 8080,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "packet-up",
          "scMaxEachPostBytes": 131072,
          "scMaxBufferedPosts": 30
        },
        "security": "none",
        "sockopt": {
          "trustedXForwardedFor": [
            "CF-Connecting-IP",
            "X-Forwarded-For"
          ]
        }
      }
    }
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

echo "=== 6. 彻底物理清场旧进程并启动服务 (45M/45M + GOGC=50) ==="

# 6.1 清理旧服务与状态锁
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

# 6.2 写入系统服务配置并尝试启动
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

export GOMEMLIMIT=45MiB
export GOGC=50

depend() { need net; }

stop_pre() {
    killall -9 xray >/dev/null 2>&1 || true
    rm -f /run/xray.pid
}
OPENRC_XRAY
    chmod +x /etc/init.d/xray

    # 不加单引号，确保 ${CF_BIN} 与 ${CF_RUN_ARGS} 真实展开写入
    cat << OPENRC_CF > /etc/init.d/cloudflared
#!/sbin/openrc-run
name="cloudflared"
command="${CF_BIN}"
command_args="${CF_RUN_ARGS}"
command_background="yes"
pidfile="/run/cloudflared.pid"
rc_ulimit="-n 65535"

export GOMEMLIMIT=45MiB
export GOGC=50

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
Description=Xray Local Loopback Service
After=network.target

[Service]
Type=simple
LimitNOFILE=65535
Environment="GOMEMLIMIT=45MiB"
Environment="GOGC=50"
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
Environment="GOMEMLIMIT=45MiB"
Environment="GOGC=50"
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

# 6.3 容器环境直接兜底拉起（过滤 Z 僵尸进程，若 OpenRC/Systemd 未拉起则直接 nohup 后台启动）
sleep 2
if ! is_alive "xray"; then
    GOMEMLIMIT=45MiB GOGC=50 nohup /usr/local/bin/xray run -c "${XRAY_CONF_DIR}/config.json" >/dev/null 2>&1 &
fi
if ! is_alive "cloudflared"; then
    GOMEMLIMIT=45MiB GOGC=50 nohup ${CF_BIN} ${CF_RUN_ARGS} >/dev/null 2>&1 &
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
# 原生自带 128KB (131072) 切片与多路复用优化的 extra 参数
EXTRA_PARAM="&extra=%7B%22scMaxEachPostBytes%22%3A131072%2C%22xmux%22%3A%7B%22maxConcurrency%22%3A%224-8%22%2C%22cMaxReuseTimes%22%3A%2232-64%22%7D%7D"
VLESS_LINK="vless://${UUID}@${FINAL_ADDR}:443?encryption=none&security=tls&sni=${CF_DOMAIN}&fp=chrome&alpn=h2&type=xhttp&host=${CF_DOMAIN}&path=${ENCODED_PATH}&mode=packet-up${EXTRA_PARAM}#Argo-XHTTP-${CF_DOMAIN}"
printf "%s\n" "$VLESS_LINK" > "$LINK_FILE"

echo ""
echo "=================================================="
echo "✅ argo-xhttp-Pure (128KB 高吞吐版) 部署完成！"
echo "=================================================="
echo "固定配置目录     : /etc/argo-xhttp/"
echo "内存与GC策略     : Xray(45M) / Cloudflare(45M), GOGC=50"
echo "上行分片大小     : 128KB (131072 Bytes) 高速切片"
echo "隧道域名 (SNI)   : ${CF_DOMAIN}"
echo "连接地址 (优选)  : ${FINAL_ADDR}"
echo "UUID             : ${UUID}"
echo "Path             : ${XHTTP_PATH}"
echo "=================================================="
echo "📋 复制下方节点链接（自带 128KB extra 优化参数），在客户端中导入："
echo ""
echo "${VLESS_LINK}"
echo ""
echo "=================================================="
echo "💡 查看当前完整节点链接命令: cat /etc/argo-xhttp/vless.link"
echo "=================================================="
