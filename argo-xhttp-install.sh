#!/bin/sh
set -e

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
    apk update && apk add --no-cache curl unzip ca-certificates openssl
elif command -v apt-get >/dev/null 2>&1; then
    OS="debian"
    apt-get update && apt-get install -y curl unzip ca-certificates openssl
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

echo ""
echo "=== 3. 配置固定隧道与节点参数 ==="
echo "--------------------------------------------------"
echo "💡 提示：请填写上方「Argo 固定隧道域名」与「Argo 隧道 Token」"
echo "   自有 CF Tunnel 可在 fscarmen CF Json 生成网："
echo "   https://fscarmen.cloudflare.now.cc/ 获取 JSON Token，"
echo "   也可手动去 Cloudflare Zero Trust 隧道后台添加（回源填 http://127.0.0.1:8080）。"
echo "--------------------------------------------------"

# 自动探测现有 Token
DETECTED_TOKEN=""
for f in /etc/systemd/system/cloudflared*.service /etc/init.d/cloudflared*; do
    if [ -f "$f" ]; then
        EXTRACTED=$(grep -oE 'eyJh[A-Za-z0-9_-]+' "$f" | head -n 1 || true)
        if [ -n "$EXTRACTED" ]; then
            DETECTED_TOKEN="$EXTRACTED"
            break
        fi
    fi
done

if [ -n "$DETECTED_TOKEN" ]; then
    echo "✅ 检测到本机已存在 Tunnel Token。"
    printf "直接回车沿用现有 Token，或粘贴新 Token 覆盖: "
    read -r INPUT_TOKEN < /dev/tty
    CF_TOKEN="${INPUT_TOKEN:-$DETECTED_TOKEN}"
else
    printf "请输入 Argo 隧道 Token (eyJh...): "
    read -r CF_TOKEN < /dev/tty
    [ -z "$CF_TOKEN" ] && { echo "❌ 错误：Token 不能为空！"; exit 1; }
fi

printf "请输入 Argo 固定隧道域名 (例如 tunnel.example.com): "
read -r CF_DOMAIN < /dev/tty
[ -z "$CF_DOMAIN" ] && { echo "❌ 错误：隧道域名不能为空！"; exit 1; }

echo ""
echo "请选择优选域名 / 连接地址（直接回车默认使用隧道域名本身）："
echo "  [0] 不优选，直接使用隧道域名 (${CF_DOMAIN})"
echo "  [1] cloudflare.182682.xyz"
echo "  [2] icook.hk"
echo "  [3] visa.com.sg"
echo "  [4] time.is"
echo "  [5] 手动输入自定义优选域名或优选 IP"
printf "请输入序号 [0-5] (默认 0): "
read -r OPT_CHOICE < /dev/tty

case "$OPT_CHOICE" in
    1) ADDR="cloudflare.182682.xyz" ;;
    2) ADDR="icook.hk" ;;
    3) ADDR="visa.com.sg" ;;
    4) ADDR="time.is" ;;
    5)
        printf "请输入你的自定义优选域名或 IP: "
        read -r CUSTOM_ADDR < /dev/tty
        ADDR="${CUSTOM_ADDR:-$CF_DOMAIN}"
        ;;
    *) ADDR="$CF_DOMAIN" ;;
esac
echo "✅ 已选定节点连接地址: ${ADDR}"

echo "=== 4. 安装纯净版 Xray-core（跳过 geoip/geosite 省内存）==="
LATEST_VER=$(curl -sL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
[ -z "$LATEST_VER" ] && LATEST_VER="v26.3.27"
XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VER}/Xray-linux-${XRAY_ARCH}.zip"

mkdir -p /tmp/xray_argo /usr/local/bin /usr/local/etc/xray
curl -L "$XRAY_URL" -o /tmp/xray_argo/xray.zip
unzip -o /tmp/xray_argo/xray.zip xray -d /usr/local/bin/
chmod +x /usr/local/bin/xray

if [ ! -f /usr/local/bin/cloudflared ] && ! command -v cloudflared >/dev/null 2>&1; then
    echo "=== 5. 下载 cloudflared 二进制文件 ==="
    CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
    curl -L "$CF_URL" -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
fi
CF_BIN=$(command -v cloudflared || echo "/usr/local/bin/cloudflared")
rm -rf /tmp/xray_argo

echo "=== 6. 生成 Xray 本地回环配置（仅监听 127.0.0.1:8080）==="
UUID=$(/usr/local/bin/xray uuid)
RAND_STR=$(openssl rand -hex 6)
XHTTP_PATH="/${RAND_STR}"
ENCODED_PATH="%2F${RAND_STR}"

cat << JSON > /usr/local/etc/xray/config.json
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

echo "=== 7. 配置双进程极限低内存守护服务 ==="
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
command_args="tunnel --no-autoupdate --protocol http2 --ha-connections 1 run --token ${CF_TOKEN}"
command_background="yes"
pidfile="/run/cloudflared.pid"

export GOMEMLIMIT=30MiB
export GOGC=50

depend() { need net xray; }
OPENRC_CF
    chmod +x /etc/init.d/cloudflared

    rc-update add xray default
    rc-update add cloudflared default
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
ExecStart=${CF_BIN} tunnel --no-autoupdate --protocol http2 --ha-connections 1 run --token ${CF_TOKEN}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SYS_CF

    systemctl daemon-reload
    systemctl enable xray cloudflared
    systemctl restart xray cloudflared
fi

# 生成带 chrome 指纹与 TLS 的 VLESS XHTTP 节点链接
VLESS_LINK="vless://${UUID}@${ADDR}:443?encryption=none&security=tls&sni=${CF_DOMAIN}&fp=chrome&alpn=h2%2Chttp%2F1.1&type=xhttp&host=${CF_DOMAIN}&path=${ENCODED_PATH}&mode=packet-up#Argo-XHTTP-${CF_DOMAIN}"

echo ""
echo "=================================================="
echo "✅ argo-xhttp-Pure 部署完成！"
echo "=================================================="
echo "本地回源地址     : http://127.0.0.1:8080"
echo "隧道域名 (SNI)   : ${CF_DOMAIN}"
echo "连接地址 (优选)  : ${ADDR}"
echo "uTLS 浏览器指纹  : chrome"
echo "=================================================="
echo "📋 复制下方节点链接，直接在 v2rayNG 中【从剪贴板导入】："
echo ""
echo "${VLESS_LINK}"
echo ""
echo "=================================================="
echo "⚠️ 提醒：请确保 Cloudflare 隧道后台 Public Hostname 指向 http://127.0.0.1:8080"
echo "💡 后续重跑管理命令：sh /root/argo-xhttp-install.sh"
echo "=================================================="
