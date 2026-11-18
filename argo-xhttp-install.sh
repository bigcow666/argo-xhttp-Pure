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

echo "=================================================="
echo "   argo-xhttp-Pure (VLESS+XHTTP + Cloudflare Argo)"
echo "   配置固定目录: /etc/argo-xhttp | 本地回环: 8080"
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
        mkswap /swapfile >/dev/null 2>&1
        swapon /swapfile >/dev/null 2>&1 || true
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
echo "=== 4. 读取或初始化固定配置 (/etc/argo-xhttp) ==="

# 兼容迁移：若固定目录尚无文件，尝试从旧版配置或本机现有服务中抓取一次并写入固定目录
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

# 读取固定文件中的所有现有值
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
    echo "--------------------------------------------------"
    echo "💡 固定隧道说明：请填写上方「Argo 固定隧道域名」与「Argo 隧道 Token」；"
    echo "   自有 CF Tunnel 可在 fscarmen CF Json 生成网："
    echo "   https://fscarmen.cloudflare.now.cc/ 获取 JSON Token（仅选了 Argo 协议才需要），"
    echo "   也可手动去 CF Zero Trust 隧道后台添加（回源填 http://127.0.0.1:8080）。"
    echo "--------------------------------------------------"

    # 固定域名读取与写入
    if [ -n "$SAVED_DOMAIN" ]; then
        echo "✅ 已锁定固定隧道域名: ${SAVED_DOMAIN}"
        printf "直接回车沿用 [${SAVED_DOMAIN}]，或输入新域名覆盖: "
        read -r INPUT_DOMAIN < /dev/tty
        if [ -n "$INPUT_DOMAIN" ]; then
            CF_DOMAIN="$INPUT_DOMAIN"
            printf "%s" "$CF_DOMAIN" > "$DOMAIN_FILE"
            echo "🔄 固定隧道域名已更新并写入 ${DOMAIN_FILE}"
        else
            CF_DOMAIN="$SAVED_DOMAIN"
        fi
    else
        while [ -z "$CF_DOMAIN" ]; do
            printf "请输入 Argo 固定隧道域名 (例如 tunnel.example.com): "
            read -r CF_DOMAIN < /dev/tty
        done
        printf "%s" "$CF_DOMAIN" > "$DOMAIN_FILE"
        echo "✅ 固定隧道域名已永久写入 ${DOMAIN_FILE}"
    fi

    # 固定 Token 读取与写入
    if [ -n "$SAVED_TOKEN" ]; then
        TOK_PREVIEW=$(echo "$SAVED_TOKEN" | cut -c 1-28)
        echo "✅ 已锁定隧道凭证 (Token/JSON): ${TOK_PREVIEW}..."
        printf "直接回车沿用现有凭证，或粘贴新 Token / JSON 覆盖: "
        read -r INPUT_TOKEN < /dev/tty
        if [ -n "$INPUT_TOKEN" ]; then
            CF_TOKEN="$INPUT_TOKEN"
            printf "%s" "$CF_TOKEN" > "$TOKEN_FILE"
            echo "🔄 隧道凭证已更新并写入 ${TOKEN_FILE}"
        else
            CF_TOKEN="$SAVED_TOKEN"
        fi
    else
        while [ -z "$CF_TOKEN" ]; do
            printf "请输入 Argo 隧道 Token (eyJh...) 或 fscarmen 生成的 JSON: "
            read -r CF_TOKEN < /dev/tty
        done
        printf "%s" "$CF_TOKEN" > "$TOKEN_FILE"
        echo "✅ 隧道凭证已永久写入 ${TOKEN_FILE}"
    fi

    # 判断 JSON 凭证还是官方 eyJh Token
    if echo "$CF_TOKEN" | grep -q '{'; then
        echo "🔧 检测到 JSON 格式凭证，正在生成 ${PERSIST_DIR}/tunnel.json 与 config.yml..."
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
        CF_RUN_ARGS="tunnel --no-autoupdate --ha-connections 1 --config ${PERSIST_DIR}/config.yml run"
    else
        CF_RUN_ARGS="tunnel --no-autoupdate --protocol http2 --ha-connections 1 run --token ${CF_TOKEN}"
    fi
else
    echo "⚡ 已选择【临时隧道】，无需 Token 与固定域名，稍后自动提取分配域名..."
    rm -f /var/log/cloudflared.log
    CF_RUN_ARGS="tunnel --no-autoupdate --protocol http2 --ha-connections 1 --url http://127.0.0.1:8080 --logfile /var/log/cloudflared.log"
fi

# ---------------- 4.4 优选域名读取与写入 ----------------
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
    echo "  [回车] 沿用已固定的优选地址 (${SAVED_ADDR})"
else
    echo "  [回车] 默认使用 [1] cloudflare.182682.xyz"
fi
printf "请输入序号 [0-6]: "
read -r OPT_CHOICE < /dev/tty

case "$OPT_CHOICE" in
    0) ADDR="$CF_DOMAIN" ;;
    1) ADDR="cloudflare.182682.xyz" ;;
    2) ADDR="cf.090227.xyz" ;;
    3) ADDR="icook.hk" ;;
    4) ADDR="visa.com.sg" ;;
    5) ADDR="time.is" ;;
    6)
        printf "请输入你的自定义优选域名或 IP: "
        read -r CUSTOM_ADDR < /dev/tty
        ADDR="${CUSTOM_ADDR:-$CF_DOMAIN}"
        ;;
    *)
        if [ -n "$SAVED_ADDR" ]; then
            ADDR="$SAVED_ADDR"
        else
            ADDR="cloudflare.182682.xyz"
        fi
        ;;
esac
printf "%s" "$ADDR" > "$ADDR_FILE"

echo "=== 5. 写入 Xray 本地回环配置（仅监听 127.0.0.1:8080）==="
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

depend() { need net; }
OPENRC_CF
    chmod +x /etc/init.d/cloudflared

    rc-update add xray default >/dev/null 2>&1 || true
    rc-update add cloudflared default >/dev/null 2>&1 || true
    rc-service cloudflared stop >/dev/null 2>&1 || true
    rc-service xray stop >/dev/null 2>&1 || true
    sleep 1
    rc-service xray start
    rc-service cloudflared start
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
After=network.target

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
    systemctl restart xray
    systemctl restart cloudflared
fi

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
    [ "$OPT_CHOICE" = "0" ] && ADDR="$CF_DOMAIN"
fi

FINAL_ADDR="${ADDR:-$CF_DOMAIN}"
VLESS_LINK="vless://${UUID}@${FINAL_ADDR}:443?encryption=none&security=tls&sni=${CF_DOMAIN}&fp=chrome&alpn=h2%2Chttp%2F1.1&type=xhttp&host=${CF_DOMAIN}&path=${ENCODED_PATH}&mode=packet-up#Argo-XHTTP-${CF_DOMAIN}"
printf "%s\n" "$VLESS_LINK" > "$LINK_FILE"

echo ""
echo "=================================================="
echo "✅ argo-xhttp-Pure 部署完成！"
echo "=================================================="
echo "固定配置目录     : /etc/argo-xhttp/"
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
echo "💡 随时查看当前节点链接命令: cat /etc/argo-xhttp/vless.link"
if [ "$TUNNEL_MODE" = "1" ] && ! echo "$CF_TOKEN" | grep -q '{'; then
    echo "⚠️ 提醒：使用官方 eyJh Token 时，请确保 CF 后台 Public Hostname 指向 http://127.0.0.1:8080"
fi
echo "=================================================="
