#!/bin/sh

GITHUB_HOME="https://github.com/bigcow666"
XR_URL="https://raw.githubusercontent.com/bigcow666/argo-xhttp-Pure/main/xr.sh"
INSTALL_URL="https://raw.githubusercontent.com/bigcow666/argo-xhttp-Pure/main/argo-xhttp-install.sh"
PERSIST_DIR="/etc/argo-xhttp"
XRAY_CONF="/usr/local/etc/xray/config.json"

# 自动安装 xr 快捷命令（持久化）
if [ ! -f /usr/local/bin/xr ]; then
    mkdir -p /usr/local/bin
    if command -v wget >/dev/null 2>&1; then
        wget -qO /usr/local/bin/xr "$XR_URL" 2>/dev/null || true
    elif command -v curl >/dev/null 2>&1; then
        curl -sL "$XR_URL" -o /usr/local/bin/xr 2>/dev/null || true
    fi
    [ -f /usr/local/bin/xr ] && chmod +x /usr/local/bin/xr
fi

is_alive() {
    ps -eo stat,comm 2>/dev/null | awk -v p="$1" '$1 !~ /Z/ && $2 == p {found=1} END {exit !found}'
}

restart_xray() {
    if command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/xray ]; then
        rc-service xray restart >/dev/null 2>&1
    elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl restart xray >/dev/null 2>&1
    else
        killall -9 xray >/dev/null 2>&1 || true
        GOMEMLIMIT=35MiB GOGC=20 nohup /usr/local/bin/xray run -c "$XRAY_CONF" >/dev/null 2>&1 &
    fi
}

install_node() {
    echo ""
    echo ">>> 正在拉取并运行原安装脚本..."
    if command -v wget >/dev/null 2>&1; then
        wget -qO- "$INSTALL_URL" | sh
    else
        curl -sL "$INSTALL_URL" | sh
    fi
}

view_nodes() {
    echo ""
    echo "=================================================="
    echo "                  当前节点信息"
    echo "=================================================="
    X_STAT="❌ 未运行"; is_alive "xray" && X_STAT="✅ 运行中"
    C_STAT="❌ 未运行"; is_alive "cloudflared" && C_STAT="✅ 运行中"
    echo "Xray 状态        : ${X_STAT}"
    echo "Cloudflared 状态 : ${C_STAT}"

    if [ -f "${PERSIST_DIR}/uuid" ]; then
        echo "当前 UUID        : $(cat "${PERSIST_DIR}/uuid")"
    fi
    if [ -f "${PERSIST_DIR}/path" ]; then
        echo "当前 Path        : $(cat "${PERSIST_DIR}/path")"
    fi
    echo "--------------------------------------------------"

    FOUND=0
    if [ -f "${PERSIST_DIR}/vless.link" ]; then
        echo "【Argo XHTTP 节点】"
        cat "${PERSIST_DIR}/vless.link"
        echo ""
        FOUND=1
    fi
    if [ -f "${PERSIST_DIR}/socks.link" ]; then
        echo "【SOCKS5 节点】"
        cat "${PERSIST_DIR}/socks.link"
        echo ""
        FOUND=1
    fi
    if [ -f "${PERSIST_DIR}/reality.link" ]; then
        echo "【Reality XHTTP 节点】"
        cat "${PERSIST_DIR}/reality.link"
        echo ""
        FOUND=1
    fi

    if [ "$FOUND" -eq 0 ]; then
        echo "⚠️ 未找到节点链接文件，请先执行 [1] 安装节点。"
    fi
    echo "=================================================="
}

change_uuid_path() {
    echo ""
    if [ ! -f "$XRAY_CONF" ] || [ ! -f "${PERSIST_DIR}/uuid" ] || [ ! -f "${PERSIST_DIR}/path" ]; then
        echo "❌ 未检测到已安装的节点配置，请先执行 [1] 安装节点。"
        return
    fi

    OLD_UUID=$(cat "${PERSIST_DIR}/uuid")
    OLD_PATH=$(cat "${PERSIST_DIR}/path")
    NEW_UUID=$(/usr/local/bin/xray uuid)
    NEW_PATH="/$(openssl rand -hex 6)"

    if [ -z "$NEW_UUID" ] || [ -z "$NEW_PATH" ]; then
        echo "❌ 生成新 UUID 或 Path 失败，请检查 xray 和 openssl。"
        return
    fi

    OLD_ENC_PATH="%2F$(echo "$OLD_PATH" | sed 's/^\///')"
    NEW_ENC_PATH="%2F$(echo "$NEW_PATH" | sed 's/^\///')"

    # 1. 更新持久化文件
    printf "%s" "$NEW_UUID" > "${PERSIST_DIR}/uuid"
    printf "%s" "$NEW_PATH" > "${PERSIST_DIR}/path"

    # 2. 更新 Xray 配置文件
    sed -i "s|${OLD_UUID}|${NEW_UUID}|g" "$XRAY_CONF"
    sed -i "s|\"path\": \"${OLD_PATH}\"|\"path\": \"${NEW_PATH}\"|g" "$XRAY_CONF"

    # 3. 同步更新节点链接文件
    for f in "${PERSIST_DIR}/vless.link" "${PERSIST_DIR}/reality.link"; do
        if [ -f "$f" ]; then
            sed -i "s|${OLD_UUID}|${NEW_UUID}|g" "$f"
            sed -i "s|${OLD_ENC_PATH}|${NEW_ENC_PATH}|g" "$f"
        fi
    done

    # 4. 重启 Xray 生效
    restart_xray
    sleep 1

    echo "✅ UUID 与 Path 已更换并重启 Xray 生效！"
    echo "   新 UUID : ${NEW_UUID}"
    echo "   新 Path : ${NEW_PATH}"
    echo ""
    view_nodes
}

uninstall_all() {
    echo ""
    echo "请选择卸载方式："
    echo "  [1] 卸载全部程序，但保留固化配置与 Token，方便下次重装直接取用 (默认)"
    echo "  [2] 彻底全部卸载，连同保存的配置与 Token 一起删除"
    echo "  [0] 取消卸载"
    printf "请输入序号 [0-2] (直接回车默认 [1]): "
    read -r UNINSTALL_CHOICE < /dev/tty
    UNINSTALL_CHOICE="${UNINSTALL_CHOICE:-1}"

    case "$UNINSTALL_CHOICE" in
        1|2) ;;
        0)
            echo "已取消卸载。"
            return
            ;;
        *)
            echo "❌ 无效输入，已取消卸载。"
            return
            ;;
    esac

    if command -v rc-service >/dev/null 2>&1; then
        rc-service cloudflared stop >/dev/null 2>&1 || true
        rc-service xray stop >/dev/null 2>&1 || true
        rc-update del cloudflared default >/dev/null 2>&1 || true
        rc-update del xray default >/dev/null 2>&1 || true
        rm -f /etc/init.d/cloudflared /etc/init.d/xray
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop cloudflared xray >/dev/null 2>&1 || true
        systemctl disable cloudflared xray >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/cloudflared.service /etc/systemd/system/xray.service
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi

    killall -9 cloudflared xray >/dev/null 2>&1 || true
    rm -rf /usr/local/bin/xray /usr/local/bin/cloudflared /usr/local/etc/xray
    rm -f /var/log/cloudflared.log /run/xray.pid /run/cloudflared.pid

    if [ "$UNINSTALL_CHOICE" = "2" ]; then
        rm -rf "$PERSIST_DIR"
        echo "✅ 已彻底卸载，程序及保存的配置与 Token 已全部删除。"
    else
        echo "✅ 程序已卸载，固化配置与 Token 已保留，下次重装可直接沿用。"
    fi
    echo "💡 快捷命令 xr 仍保留方便下次重装，如需一并删除请执行: rm -f /usr/local/bin/xr"
}

while true; do
    echo ""
    echo "=================================================="
    echo "          argo-xhttp-Pure 管理菜单"
    echo "  GitHub  : ${GITHUB_HOME}"
    echo "  快捷命令: 随时在终端输入 xr 呼出本菜单"
    echo "=================================================="
    echo "  1. 安装 / 重新配置节点"
    echo "  2. 查看节点链接与状态"
    echo "  3. 更换随机 UUID 和 Path"
    echo "  4. 卸载 Xray 和 cloudflared"
    echo "  0. 退出"
    echo "=================================================="
    printf "请输入序号 [0-4]: "
    read -r MENU_CHOICE < /dev/tty

    case "$MENU_CHOICE" in
        1) install_node ;;
        2) view_nodes ;;
        3) change_uuid_path ;;
        4) uninstall_all ;;
        0) exit 0 ;;
        *) echo "❌ 无效输入，请输入 0-4。" ;;
    esac
done
