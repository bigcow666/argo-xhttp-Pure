#!/bin/sh

# ================= XPadding Obfs 自定义参数区 =================
XPADDING_BYTES="100-1000"
XPADDING_HEADER="Cow-App-Context"
XPADDING_PLACEMENT="header"
XPADDING_METHOD="tokenish"
# ==============================================================

GITHUB_HOME="https://github.com/bigcow666"
XR_URL="https://raw.githubusercontent.com/bigcow666/argo-xhttp-Pure/main/xr.sh"
INSTALL_URL="https://raw.githubusercontent.com/bigcow666/argo-xhttp-Pure/main/argo-xhttp-install.sh"
PERSIST_DIR="/etc/argo-xhttp"
XRAY_CONF="/usr/local/etc/xray/config.json"

# 每次启动自动静默更新覆盖 /usr/local/bin/xr（带超时防卡死，有新版自动重载）
if [ "${XR_UPDATED:-0}" != "1" ]; then
    mkdir -p /usr/local/bin
    TMP_XR="/usr/local/bin/xr.tmp"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 3 --max-time 5 "$XR_URL" -o "$TMP_XR" 2>/dev/null || true
    elif command -v wget >/dev/null 2>&1; then
        wget -qT 5 -O "$TMP_XR" "$XR_URL" 2>/dev/null || true
    fi
    if [ -s "$TMP_XR" ] && grep -q "argo-xhttp-Pure" "$TMP_XR" 2>/dev/null; then
        if [ ! -f /usr/local/bin/xr ] || ! cmp -s "$TMP_XR" /usr/local/bin/xr; then
            mv -f "$TMP_XR" /usr/local/bin/xr
            chmod +x /usr/local/bin/xr
            XR_UPDATED=1 exec /usr/local/bin/xr
        else
            rm -f "$TMP_XR"
        fi
    else
        rm -f "$TMP_XR"
    fi
fi

# 退出时高亮提示快捷命令（无论选 0 退出还是 Ctrl+C 都会触发）
trap 'printf "\n\033[1;32m💡 随时在终端输入 \033[1;33mxr\033[1;32m 即可再次打开本脚本设置！\033[0m\n\n"' EXIT
trap 'exit 0' INT

is_alive() {
    ps -eo stat,comm 2>/dev/null | awk -v p="$1" '$1 !~ /Z/ && $2 == p {found=1} END {exit !found}'
}

url_encode() {
    printf "%s" "$1" | sed \
        -e 's/%/%25/g' \
        -e 's/ /%20/g' \
        -e 's/"/%22/g' \
        -e 's/{/%7B/g' \
        -e 's/}/%7D/g' \
        -e 's/:/%3A/g' \
        -e 's/,/%2C/g' \
        -e 's/\[/%5B/g' \
        -e 's/\]/%5D/g' \
        -e 's/\//%2F/g' \
        -e 's/+/%2B/g' \
        -e 's/=/%3D/g' \
        -e 's/&/%26/g' \
        -e 's/?/%3F/g' \
        -e 's/#/%23/g'
}

pause_return() {
    echo ""
    echo "--------------------------------------------------"
    printf "按 [回车] 返回主菜单，或输入 [0] 退出: "
    read -r NEXT_ACT < /dev/tty
    [ "$NEXT_ACT" = "0" ] && exit 0
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

get_obfs_state() {
    if [ -f "${PERSIST_DIR}/obfs_enable" ]; then
        cat "${PERSIST_DIR}/obfs_enable"
    elif [ -f "$XRAY_CONF" ] && grep -q '"xPaddingObfsMode": true' "$XRAY_CONF" 2>/dev/null; then
        echo "1"
    else
        echo "0"
    fi
}

install_node() {
    clear 2>/dev/null || true
    echo "=================================================="
    echo "              [1] 安装 / 重新配置节点"
    echo "=================================================="
    if [ -f "$XRAY_CONF" ]; then
        printf "⚠️ 检测到本机已安装节点，确认要重新运行安装脚本吗？[y/N] (回车取消): "
        read -r INS_CONFIRM < /dev/tty
        if [ "$INS_CONFIRM" != "y" ] && [ "$INS_CONFIRM" != "Y" ]; then
            echo "已取消操作。"
            return
        fi
    fi

    echo ">>> 正在拉取并运行原安装脚本..."
    if command -v wget >/dev/null 2>&1; then
        wget -qO- "$INSTALL_URL" | sh
    else
        curl -fsSL "$INSTALL_URL" | sh
    fi
}

show_links() {
    X_STAT="❌ 未运行"; is_alive "xray" && X_STAT="✅ 运行中"
    C_STAT="❌ 未运行"; is_alive "cloudflared" && C_STAT="✅ 运行中"
    OBFS_CUR=$(get_obfs_state)
    if [ "$OBFS_CUR" = "1" ]; then
        OBFS_TXT="开启 (${XPADDING_PLACEMENT} / ${XPADDING_HEADER} / ${XPADDING_METHOD})"
    else
        OBFS_TXT="关闭 (默认 xPaddingBytes)"
    fi

    echo "Xray 状态        : ${X_STAT}"
    echo "Cloudflared 状态 : ${C_STAT}"
    echo "XPadding Obfs    : ${OBFS_TXT}"

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
}

view_nodes() {
    clear 2>/dev/null || true
    echo "=================================================="
    echo "              [2] 当前节点链接与状态"
    echo "=================================================="
    show_links
}

change_uuid_path() {
    clear 2>/dev/null || true
    echo "=================================================="
    echo "             [3] 更换随机 UUID 和 Path"
    echo "=================================================="
    if [ ! -f "$XRAY_CONF" ] || [ ! -f "${PERSIST_DIR}/uuid" ] || [ ! -f "${PERSIST_DIR}/path" ]; then
        echo "❌ 未检测到已安装的节点配置，请先执行 [1] 安装节点。"
        return
    fi

    OLD_UUID=$(cat "${PERSIST_DIR}/uuid")
    OLD_PATH=$(cat "${PERSIST_DIR}/path")
    echo "当前 UUID : ${OLD_UUID}"
    echo "当前 Path : ${OLD_PATH}"
    echo "--------------------------------------------------"
    printf "⚠️ 确认更换为新的随机 UUID 和 Path？（旧节点将失效）[y/N] (回车取消): "
    read -r CHG_CONFIRM < /dev/tty
    if [ "$CHG_CONFIRM" != "y" ] && [ "$CHG_CONFIRM" != "Y" ]; then
        echo "已取消更换。"
        return
    fi

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

    echo ""
    echo "✅ UUID 与 Path 已更换并重启 Xray 生效！"
    echo "--------------------------------------------------"
    show_links
}

toggle_obfs() {
    clear 2>/dev/null || true
    echo "=================================================="
    echo "        [4] 切换 Argo XPadding Obfs 开关"
    echo "=================================================="
    if [ ! -f "$XRAY_CONF" ] || [ ! -f "${PERSIST_DIR}/vless.link" ]; then
        echo "❌ 未检测到已安装的节点配置，请先执行 [1] 安装节点。"
        return
    fi

    CUR_OBFS=$(get_obfs_state)
    if [ "$CUR_OBFS" = "1" ]; then
        echo "当前状态: ✅ 已开启 (${XPADDING_PLACEMENT} / ${XPADDING_HEADER} / ${XPADDING_METHOD})"
    else
        echo "当前状态: ⚪ 已关闭 (默认 xPaddingBytes)"
    fi
    echo "--------------------------------------------------"
    echo "  [1] 开启 XPadding Obfs (${XPADDING_PLACEMENT}: ${XPADDING_HEADER} + maxConnections: 1-3)"
    echo "  [2] 关闭 XPadding Obfs (恢复默认 + maxConcurrency: 2-4)"
    echo "  [0] 取消并返回"
    echo "--------------------------------------------------"
    printf "请选择 [0-2]: "
    read -r OBFS_OPT < /dev/tty

    case "$OBFS_OPT" in
        1) NEW_OBFS="1" ;;
        2) NEW_OBFS="0" ;;
        0|"")
            echo "已取消操作。"
            return
            ;;
        *)
            echo "❌ 无效输入，已取消操作。"
            return
            ;;
    esac

    # 1. 更新持久化状态
    mkdir -p "$PERSIST_DIR"
    printf "%s" "$NEW_OBFS" > "${PERSIST_DIR}/obfs_enable"

    # 2. 更新 Xray 配置文件中的 argo-xhttp-in 混淆字段
    TMP_CONF="${XRAY_CONF}.tmp"
    awk -v enable="$NEW_OBFS" \
        -v bytes="$XPADDING_BYTES" \
        -v header="$XPADDING_HEADER" \
        -v placement="$XPADDING_PLACEMENT" \
        -v method="$XPADDING_METHOD" '
        /"xPaddingObfsMode":|"xPaddingKey":|"xPaddingHeader":|"xPaddingPlacement":|"xPaddingMethod":/ { next }
        /"xPaddingBytes":/ {
            if (enable == "1") {
                printf "          \"xPaddingBytes\": \"%s\",\n", bytes
                printf "          \"xPaddingObfsMode\": true,\n"
                printf "          \"xPaddingHeader\": \"%s\",\n", header
                printf "          \"xPaddingPlacement\": \"%s\",\n", placement
                printf "          \"xPaddingMethod\": \"%s\"\n", method
            } else {
                printf "          \"xPaddingBytes\": \"%s\"\n", bytes
            }
            next
        }
        { print }
    ' "$XRAY_CONF" > "$TMP_CONF" && mv -f "$TMP_CONF" "$XRAY_CONF"

    # 3. 动态编码并更新 vless.link 中的 extra 参数
    if [ "$NEW_OBFS" = "1" ]; then
        EXTRA_JSON="{\"xPaddingBytes\":\"${XPADDING_BYTES}\",\"xPaddingObfsMode\":true,\"xPaddingHeader\":\"${XPADDING_HEADER}\",\"xPaddingPlacement\":\"${XPADDING_PLACEMENT}\",\"xPaddingMethod\":\"${XPADDING_METHOD}\",\"xmux\":{\"maxConnections\":\"1-3\",\"hMaxRequestTimes\":\"100-200\",\"hMaxReusableSecs\":\"30-60\",\"hKeepAlivePeriod\":15}}"
    else
        EXTRA_JSON="{\"xPaddingBytes\":\"${XPADDING_BYTES}\",\"xmux\":{\"maxConcurrency\":\"2-4\",\"hMaxRequestTimes\":\"100-200\",\"hMaxReusableSecs\":\"30-60\",\"hKeepAlivePeriod\":15}}"
    fi
    ENC_EXTRA=$(url_encode "$EXTRA_JSON")
    sed -i "s|extra=[^#]*|extra=${ENC_EXTRA}|g" "${PERSIST_DIR}/vless.link"

    # 4. 重启 Xray 生效
    restart_xray
    sleep 1

    echo ""
    echo "✅ XPadding Obfs 状态已更新并重启 Xray 生效！"
    printf "\033[1;33m⚠️  重要提示：您已更改 XPadding Obfs 选项，必须重新导入下方节点链接才能生效！\033[0m\n"
    echo "--------------------------------------------------"
    show_links
}

uninstall_all() {
    clear 2>/dev/null || true
    echo "=================================================="
    echo "            [5] 卸载 Xray 和 cloudflared"
    echo "=================================================="
    echo "请选择卸载方式："
    echo "  [1] 卸载全部程序，但保留固化配置与 Token，方便下次重装直接取用 (默认)"
    echo "  [2] 彻底全部卸载，连同保存的配置与 Token 一起删除"
    echo "  [0] 取消卸载，返回主菜单"
    echo "--------------------------------------------------"
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
    clear 2>/dev/null || true
    echo "=================================================="
    echo "          argo-xhttp-Pure 管理菜单"
    echo "  GitHub  : ${GITHUB_HOME}"
    echo "  快捷命令: 随时在终端输入 xr 呼出本菜单"
    echo "=================================================="
    echo "  1. 安装 / 重新配置节点"
    echo "  2. 查看节点链接与状态"
    echo "  3. 更换随机 UUID 和 Path"
    echo "  4. 切换 Argo XPadding Obfs 开关"
    echo "  5. 卸载 Xray 和 cloudflared"
    echo "  0. 退出"
    echo "=================================================="
    printf "请输入序号 [0-5]: "
    read -r MENU_CHOICE < /dev/tty

    case "$MENU_CHOICE" in
        1) install_node; pause_return ;;
        2) view_nodes; pause_return ;;
        3) change_uuid_path; pause_return ;;
        4) toggle_obfs; pause_return ;;
        5) uninstall_all; pause_return ;;
        0) exit 0 ;;
        *)
            echo "❌ 无效输入，请输入 0-5。"
            sleep 1
            ;;
    esac
done
