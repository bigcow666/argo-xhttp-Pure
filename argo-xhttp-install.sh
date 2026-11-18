#!/bin/sh
set -e

CONF_DIR="/usr/local/etc/xray"
STATE_FILE="${CONF_DIR}/argo_state.conf"
mkdir -p "$CONF_DIR"

echo "=================================================="
echo "   argo-xhttp-Pure (VLESS+XHTTP + Cloudflare Argo)"
echo "   专为 128MB 极限内存 VPS 优化 | 本地回环 8080 零端口"
echo "=================================================="

echo "=== 1. 检查系统环境与架构 ==="
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) XRAY_ARCH="64"; CF_ARCH="amd64" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a"; CF_ARCH="arm64" ;;
    *) echo "❌ 不支持的架构: $ARCH"; exit 1 ;;
esac

if command -v apk >/dev/null 2>&1; then
    OS="alpine"
    apk update && apk add --no-cache curl unzip ca-certificates openssl grep sed
elif command -v apt-get >/dev/null 2>&1; then
    OS="debian"
    apt-get update && apt-get install -y curl unzip ca-certificates openssl grep sed
else
    echo "❌ 仅支持 Alpine 或 Debian/Ubuntu 系统"; exit 1
fi

echo "=== 2. 检查并开启 256MB Swap 虚拟内存（防 128MB OOM）==="
if [ "$(free -m | awk '/^Swap:/ {print $2}')" -eq 0 ]; then
    if [ ! -f /swapfile ]; then
        dd if=/dev/zero of=/swapfile bs=1M count=256 status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile || true
        grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
        echo "✅ 已开启 256MB Swap 兜底。"
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
echo "=== 4. 自动检测历史配置 (UUID / Path / 隧道参数) ==="
# 载入历史状态文件
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

# 若无状态文件，尝试从现有 config.json 和系统服务中提取
if [ -z "$SAVED_UUID" ] && [ -f "${CONF_DIR}/config.json" ]; then
    SAVED_UUID=$(grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' "${CONF_DIR}/config.json" | head -n 1 || true)
    SAVED_PATH=$(grep '"path":' "${CONF_DIR}/config.json" | sed -E 's/.*"path":[[:space:]]*"([^"]+)".*/\1/' | head -n 1 || true)
fi

if [ -z "$SAVED_TOKEN" ]; then
    for f in /etc/systemd/system/cloudflared*.service /etc/init.d/cloudflared*; do
        if [ -f "$f" ]; then
            EXTRACTED=$(grep -oE 'eyJh[A-Za-z0-9_-]+' "$f" | head -n 1 || true)
            if [ -n "$EXTRACTED" ]; then
                SAVED_TOKEN="$EXTRACTED"
                break
            fi
        fi
    done
fi

# 4.1 确认或生成 UUID 与 Path
if [ -n "$SAVED_UUID" ] && [ -n "$SAVED_PATH" ]; then
    echo "✅ 检测到已有 Xray 节点配置："
    echo "   UUID : ${SAVED_UUID}"
    echo "   Path : ${SAVED_PATH}"
    printf "是否保留现有 UUID 和 Path？[Y/n (直接回车保留，输入 n 重新生成)]: "
    read -r KEEP_UUID < /dev/tty
    if [ "$KEEP_UUID" = "n" ] || [ "$KEEP_UUID" = "N" ]; then
        UUID=$(/usr/local/bin/xray uuid)
        XHTTP_PATH="/$(openssl rand -hex 6)"
        echo "🔄 已重新生成 UUID 与 Path。"
    else
        UUID="$SAVED_UUID"
        XHTTP_PATH="$SAVED_PATH"
    fi
else
    UUID=$(/usr/local/bin/xray uuid)
    XHTTP_PATH="/$(openssl rand -hex 6)"
fi
RAND_STR=$(echo "$XHTTP_PATH" | sed 's/^\///')
ENCODED_PATH="%2F${RAND_STR}"

# 4.2 选择隧道模式（固定隧道 vs 临时隧道）
echo ""
echo "请选择 Cloudflare Argo 隧道模式："
echo "  [1] 固定隧道 (推荐，绑定自有域名，支持 Token 或 fscarmen JSON)"
echo "  [2] 临时隧道 (免账号免域名，自动申请 trycloudflare.com 临时域名)"
printf "请输入序号 [1-2] (默认 1): "
read -r TUNNEL_MODE < /dev/tty
TUNNEL_MODE="${TUNNEL_MODE:-1}"

if [ "$TUNNEL_MODE" = "1" ]; then
    echo "--------------------------------------------------"
    echo "💡 固定隧道说明：请填写「Argo 固定隧道域名」与「Argo 隧道 Token」；"
    echo "   自有 CF Tunnel 可在 fscarmen CF Json 生成网："
    echo "   https://fscarmen.cloudflare.now.cc/ 获取 JSON Token（仅选了 Argo 协议才需要），"
    echo "   也可手动去 CF Zero Trust 隧道后台添加（回源填 http://127.0.0.1:8080）。"
    echo "--------------------------------------------------"

    if [ -n "$SAVED_DOMAIN" ]; then
        echo "✅ 检测到已有固定隧道域名: ${SAVED_DOMAIN}"
        printf "直接回车沿用该域名，或输入新域名覆盖: "
        read -r INPUT_DOMAIN < /dev/tty
        CF_DOMAIN="${INPUT_DOMAIN:-$SAVED_DOMAIN}"
    else
        printf "请输入 Argo 固定隧道域名 (例如 tunnel.example.com): "
        read -r CF_DOMAIN < /dev/tty
        [ -z "$CF_DOMAIN" ] && { echo "❌ 错误：固定隧道域名不能为空！"; exit 1; }
    fi

    if [ -n "$SAVED_TOKEN" ]; then
        echo "✅ 检测到已有隧道凭证 (Token / JSON)。"
        printf "直接回车沿用现有凭证，或粘贴新 Token / JSON 覆盖: "
        read -r INPUT_TOKEN < /dev/tty
        CF_TOKEN="${INPUT_TOKEN:-$SAVED_TOKEN}"
    else
        printf "请输入 Argo 隧道 Token (eyJh...) 或 fscarmen 生成的 JSON: "
        read -r CF_TOKEN < /dev/tty
        [ -z "$CF_TOKEN" ] && { echo "❌ 错误：隧道凭证不能为空！"; exit 1; }
    fi

    # 判断用户输入的是 fscarmen 的 JSON 还是官方 eyJh Token
    if echo "$CF_TOKEN" | grep -q '{'; then
        echo "🔧 检测到 JSON 格式 Token，正在生成本地隧道证书与 config.yml..."
        echo "$CF_TOKEN" > "${CONF_DIR}/tunnel.json"
        TUNNEL_ID=$(echo "$CF_TOKEN" | grep -oE '"TunnelID":[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"/\1/')
        cat << YAML > "${CONF_DIR}/config.yml"
tunnel: ${TUNNEL_ID}
credentials-file: ${CONF_DIR}/tunnel.json
protocol: http2
ingress:
  - hostname: ${CF_DOMAIN}
    service: http://127.0.0.1:8080
  - service: http_status:404
YAML
        CF_RUN_ARGS="tunnel --no-autoupdate --ha-connections 1 --config ${CONF_DIR}/config.yml run"
    else
        CF_RUN_ARGS="tunnel --no-autoupdate --protocol http2 --ha-connections 1 run --token ${CF_TOKEN}"
    fi
else
    echo "⚡ 已选择【临时隧道】，无需输入 Token 与域名，稍后将自动提取分配的域名..."
    rm -f /var/log/cloudflared.log
    CF_RUN_ARGS="tunnel --no-autoupdate --protocol http2 --ha-connections 1 --url http://127.0.0.1:8080 --logfile /var/log/cloudflared.log"
fi

# 4.3 选择优选域名或 IP
echo ""
echo "请选择优选域名 / 客户端连接地址："
echo "  [0] 不优选，直接使用隧道域名本身"
echo "  [1] cloudflare.182682.xyz (推荐)"
echo "  [2] cf.090227.xyz"
echo "  [3] icook.hk"
echo "  [4] visa.com.sg"
echo "  [5] time.is"
echo "  [6] 手动输入自定义优选域名或优选 IP"
if [ -n "$SAVED_ADDR" ]; then
    echo "  [回车] 沿用上次优选地址 (${SAVED_ADDR})"
fi
printf "请输入序号 [0-6]: "
read -r OPT_CHOICE < /dev/tty

case "$OPT_CHOICE" in
    0) ADDR="" ;;
    1) ADDR="cloudflare.182682.xyz" ;;
    2) ADDR="cf.090227.xyz" ;;
    3) ADDR="icook.hk" ;;
    4) ADDR="visa.com.sg" ;;
    5) ADDR="time.is" ;;
    6)
        printf "请输入你的自定义优选域名或 IP: "
        read -r CUSTOM_ADDR < /dev/tty
        ADDR="$CUSTOM_ADDR"
        ;;
    *)
        ADDR="${SAVED_ADDR:-}"
        ;;
esac

echo "=== 5. 写入 Xray 本地回环配置（仅监听 127.0.0.1:8080）==="
cat << JSON > "${CONF_DIR}/config.json"
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
          "mode": "packet-up"
        },
        "security": "none"
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

echo "=== 6. 启动双进程极限低内存守护服务 ==="
if [ "$OS" = "alpine" ]; then
    cat << 'OPENRC_XRAY' > /etc/init.d/xray
#!/sbin/openrc-run
name="xray"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"

export GOMEMLIMIT=35MiB
export GOGC=50

depend() { need net; }
OPENRC_XRAY
    chmod +x /etc/init.d/xray

    cat << OPENRC_CF > /etc/init.d/cloudflared
#!/sbin/openrc-run
name="cloudflared"
command="${CF_BIN}"
command_args="${CF_RUN_ARGS}"
command_background="yes"
pidfile="/run/cloudflared.pid"

export GOMEMLIMIT=30MiB
export GOGC=50

depend() { need net xray; }
OPENRC_CF
    chmod +x /etc/init.d/cloudflared

    rc-update add xray default >/dev/null 2>&1 || true
    rc-update add cloudflared default >/dev/null 2>&1 || true
    rc-service xray restart
    rc-service cloudflared restart
else
    cat << 'SYS_XRAY' > /etc/systemd/system/xray.service
[Unit]
Description=Xray Local Loopback Service
After=network.target

[Service]
Type=simple
Environment="GOMEMLIMIT=35MiB"
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
After=network.target xray.service

[Service]
Type=simple
Environment="GOMEMLIMIT=30MiB"
Environment="GOGC=50"
ExecStart=${CF_BIN} ${CF_RUN_ARGS}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SYS_CF

    systemctl daemon-reload
    systemctl enable xray cloudflared >/dev/null 2>&1 || true
    systemctl restart xray cloudflared
fi

# 若为临时隧道，等待提取 trycloudflare.com 域名
if [ "$TUNNEL_MODE" = "2" ]; then
    echo "⏳ 正在等待 Cloudflare 分配临时隧道域名 (约 3~8 秒)..."
    CF_DOMAIN=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 1
        if [ -f /var/log/cloudflared.log ]; then
            CF_DOMAIN=$(grep -oE 'https://[a-zA-Z0-9-]+.trycloudflare.com' /var/log/cloudflared.log | head -n 1 | sed 's/https:\/\///' || true)
            [ -n "$CF_DOMAIN" ] && break
        fi
    done
    if [ -z "$CF_DOMAIN" ]; then
        echo "⚠️ 未能在 12 秒内抓到临时域名，请稍后执行 grep trycloudflare /var/log/cloudflared.log 查看。"
        CF_DOMAIN="请替换为日志中的trycloudflare域名"
    else
        echo "✅ 成功获取临时隧道域名: ${CF_DOMAIN}"
    fi
fi

# 若未指定优选地址，则默认使用隧道域名
FINAL_ADDR="${ADDR:-$CF_DOMAIN}"

# 保存状态供下次重跑自动读取
cat << STATE > "$STATE_FILE"
SAVED_UUID='${UUID}'
SAVED_PATH='${XHTTP_PATH}'
SAVED_DOMAIN='${CF_DOMAIN}'
SAVED_TOKEN='${CF_TOKEN}'
SAVED_ADDR='${ADDR}'
STATE
chmod 600 "$STATE_FILE"

VLESS_LINK="vless://${UUID}@${FINAL_ADDR}:443?encryption=none&security=tls&sni=${CF_DOMAIN}&fp=chrome&alpn=h2%2Chttp%2F1.1&type=xhttp&host=${CF_DOMAIN}&path=${ENCODED_PATH}&mode=packet-up#Argo-XHTTP-${CF_DOMAIN}"

echo ""
echo "=================================================="
echo "✅ argo-xhttp-Pure 部署完成！"
echo "=================================================="
echo "隧道类型         : $([ "$TUNNEL_MODE" = "1" ] && echo "固定隧道" || echo "临时隧道 (重启会变)")"
echo "本地回源地址     : http://127.0.0.1:8080"
echo "隧道域名 (SNI)   : ${CF_DOMAIN}"
echo "连接地址 (优选)  : ${FINAL_ADDR}"
echo "UUID             : ${UUID}"
echo "Path             : ${XHTTP_PATH}"
echo "uTLS 浏览器指纹  : chrome"
echo "=================================================="
echo "📋 复制下方节点链接，直接在 v2rayNG 中【从剪贴板导入】："
echo ""
echo "${VLESS_LINK}"
echo ""
echo "=================================================="
if [ "$TUNNEL_MODE" = "1" ] && ! echo "$CF_TOKEN" | grep -q '{'; then
    echo "⚠️ 提醒：使用官方 eyJh Token 时，请确保 CF 后台 Public Hostname 指向 http://127.0.0.1:8080"
    echo "=================================================="
fi
