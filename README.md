# argo-xhttp-Pure

专为 **128MB 极限内存 VPS** 打造的纯净版 **Xray (VLESS + XHTTP) + Cloudflare Argo 固定隧道** 一键部署脚本。

### 核心特性
- **零外部端口暴露**：Xray 仅监听本地回环 `127.0.0.1:8080` 明文端口，无需申请 SSL 证书，公网零端口扫描风险。
- **极限低内存优化**：跳过庞大的 `geoip.dat` / `geosite.dat` 规则文件，内置锁定 `GOMEMLIMIT` 与 `GOGC` 垃圾回收上限，强制 `cloudflared` 单连接 HTTP/2 模式并自动挂载 256MB Swap 兜底，双进程常驻内存仅约 **65MB**。
- **开箱即用**：自动识别 `x86_64` / `arm64` 架构，兼容 **Alpine Linux** 与 **Debian / Ubuntu**；支持自动探测本机已有 Token、内置多组优选域名菜单，部署完成后直接生成带 Chrome uTLS 指纹的 `vless://` 节点链接。

---

### 一键安装命令

**方式一：推荐（自动适配环境补装 `curl`，最稳定）**
```bash
curl -fsSL https://raw.githubusercontent.com/bigcow666/argo-xhttp-Pure/main/argo-xhttp-install.sh | sh
```
**方式二：极简（直接使用系统自带 wget）**
```bash
wget -qO- https://raw.githubusercontent.com/bigcow666/argo-xhttp-Pure/main/argo-xhttp-install.sh | sh
```
说明
Cloudflare Zero Trust 后台设置：
​进入 Networks -> Tunnels，选择你的固定隧道并进入 Public Hostname。
​Service Type 选择 HTTP，URL 填写 127.0.0.1:8080。
