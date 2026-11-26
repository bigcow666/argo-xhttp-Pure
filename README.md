# argo-xhttp-Pure

专为 **128MB 极限内存 NAT VPS** 打造的纯净版 **Xray (VLESS + XHTTP) + Cloudflare Argo 固定隧道** 一键部署脚本。

## 核心特性

- **零外部端口暴露**：Xray 仅监听本地回环 `127.0.0.1:8080` 明文端口，无需申请 SSL 证书，公网零端口扫描风险。
- **极限低内存优化**：跳过庞大的 `geoip.dat` / `geosite.dat` 规则文件，内置锁定 `GOMEMLIMIT` 与 `GOGC` 垃圾回收上限，强制 `cloudflared` 单连接 HTTP/2 模式并自动挂载 256MB Swap 兜底，双进程常驻内存仅约 **65MB**。
- **开箱即用**：自动识别 `x86_64` / `arm64` 架构，兼容 **Alpine Linux** 与 **Debian / Ubuntu**；支持自动探测本机已有 Token、内置多组优选域名菜单，部署完成后直接生成带 Chrome uTLS 指纹的 `vless://` 节点链接。

---

## 一键安装命令

**方式一：使用 curl**（需系统已安装 `curl`，最稳定）
```bash
curl -fsSL https://raw.githubusercontent.com/bigcow666/argo-xhttp-Pure/main/xr.sh | sh
```

**方式二：使用 wget（推荐）**（直接使用系统自带 `wget`）
```bash
wget -qO- https://raw.githubusercontent.com/bigcow666/argo-xhttp-Pure/main/xr.sh | sh
```

---

## Cloudflare Zero Trust 后台设置

1. 进入 **Networks -> Tunnels**，选择你的固定隧道并进入 **Public Hostname**。
2. **Service Type** 选择 `HTTP`，**URL** 填写 `127.0.0.1:8080`。

> 💡 推荐开启 **VLESS Encryption (enc)** 和 **Vision Flow (`xtls-rprx-vision`)**。

---

## XHTTP `extra` 配置（心跳包 / Obfs / XMUX）

将下方对应的 JSON 代码粘贴到 v2rayN / v2rayNG 等客户端 XHTTP 节点的 `extra` 输入框中即可。

### 1. 开启 `xPaddingObfsMode` 时

**限制 `maxConnections`（默认推荐）：**
```json
{
  "xPaddingBytes": "100-1000",
  "xPaddingObfsMode": true,
  "xPaddingHeader": "Cow-App-Context",
  "xPaddingPlacement": "header",
  "xPaddingMethod": "tokenish",
  "xmux": {
    "maxConnections": "1-3",
    "hMaxRequestTimes": "100-200",
    "hMaxReusableSecs": "30-60",
    "hKeepAlivePeriod": 15
  }
}
```

**限制 `maxConcurrency`（备用）：**
```json
{
  "xPaddingBytes": "100-1000",
  "xPaddingObfsMode": true,
  "xPaddingHeader": "Cow-App-Context",
  "xPaddingPlacement": "header",
  "xPaddingMethod": "tokenish",
  "xmux": {
    "maxConcurrency": "2-4",
    "hMaxRequestTimes": "100-200",
    "hMaxReusableSecs": "30-60",
    "hKeepAlivePeriod": 15
  }
}
```

### 2. 关闭 Obfs 时

**过 CF 场景（默认，模式选 `packet-up`）：**
> 垃圾线路建议设置 `maxConcurrency`（限制每条管道里的线缆数量，但不限制管道数量）。数值越低越好，可防止单条管道堵塞导致管道内所有连接同时卡死，影响多个 App。

```json
{
  "xPaddingBytes": "100-1000",
  "xmux": {
    "maxConcurrency": "2-4",
    "hMaxRequestTimes": "100-200",
    "hMaxReusableSecs": "30-60",
    "hKeepAlivePeriod": 15
  }
}
```

**直连场景（模式选 `auto`）：**
> 直连建议设置 `maxConnections`（限制连接管道总数）。数值越低越好，因为 Chrome 浏览器本身不会建立过多连接管道，设高了反而容易暴露特征。

```json
{
  "xPaddingBytes": "100-1000",
  "xmux": {
    "maxConnections": "1-3",
    "hMaxRequestTimes": "100-200",
    "hMaxReusableSecs": "30-60",
    "hKeepAlivePeriod": 15
  }
}
```

---

## XMUX 参数说明

| 参数 | 作用说明 |
| :--- | :--- |
| `maxConcurrency` | 限制每条管道里的最大线缆（并发流）数量，但不限制总管道数。 |
| `maxConnections` | 限制连接管道总数，但不限制每条管道里的线缆数量。 |
| `hMaxRequestTimes` | 一条管道传输多少次请求后主动关闭；手机网络建议适度偏低，防止切屏假死。 |
| `hMaxReusableSecs` | 一条管道最长存活时间（秒）；手机网络建议适度偏低，防止切屏假死。 |
| `hKeepAlivePeriod` | 心跳保活间隔（秒）；过 CF 时仅能保活「客户端 ↔ CF 边缘节点」段。 |
