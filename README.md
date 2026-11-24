# argo-xhttp-Pure

专为 **128MB 极限内存 Nat VPS** 打造的纯净版 **Xray (VLESS + XHTTP) + Cloudflare Argo 固定隧道** 一键部署脚本。

### 核心特性
- **零外部端口暴露**：Xray 仅监听本地回环 `127.0.0.1:8080` 明文端口，无需申请 SSL 证书，公网零端口扫描风险。
- **极限低内存优化**：跳过庞大的 `geoip.dat` / `geosite.dat` 规则文件，内置锁定 `GOMEMLIMIT` 与 `GOGC` 垃圾回收上限，强制 `cloudflared` 单连接 HTTP/2 模式并自动挂载 256MB Swap 兜底，双进程常驻内存仅约 **65MB**。
- **开箱即用**：自动识别 `x86_64` / `arm64` 架构，兼容 **Alpine Linux** 与 **Debian / Ubuntu**；支持自动探测本机已有 Token、内置多组优选域名菜单，部署完成后直接生成带 Chrome uTLS 指纹的 `vless://` 节点链接。

---

### 一键安装命令

**方式一：复curl 需系统已安装 `curl`，最稳定）**
```bash
curl -fsSL https://raw.githubusercontent.com/bigcow666/argo-xhttp-Pure/main/xr.sh | sh
```
**方式二 推荐（直接使用系统自带 wget）**
```bash
wget -qO- https://raw.githubusercontent.com/bigcow666/argo-xhttp-Pure/main/xr.sh | sh
```
说明
Cloudflare Zero Trust 后台设置：
​进入 Networks -> Tunnels，选择你的固定隧道并进入 Public Hostname。
​Service Type 选择 HTTP，URL 填写 127.0.0.1:8080。

推荐开启enc和vison flow

**#xhttp #心跳包**

**垃圾线路设置 maxConcurrency**，理解为限制每条管道里的线缆数量，但不限制管道数量。越低越好，防止单条管道堵塞导致管道内所有连接都连不上，影响多种 App。

**过CF（模式选 packet-up）**
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

**直连设置 maxConnections**，越低越好，理解为限制连接管道总数。Chrome 浏览器不会建立太多管道，设置高了容易暴露特征。（模式选 auto）
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

**maxConcurrency** 限制每条管道里的最大线缆数量，但不限制多少管道

**maxConnections** 限制连接管道总数，但不限制每条管道里的线缆数量。

**hMaxRequestTimes** 一条管道传输多少次关闭，手机网络适度偏低，防止切屏假死

**hMaxReusableSecs** 一条管道多长时间过期，手机网络适度偏低，防止切屏假死

**hKeepAlivePeriod** 心跳保活时间 过CF时 只能保活客户端到cf边缘节点

