# vps8 DNS Manager

一站式管理 [vps8](https://vps8.zz.cd) 的 DNS 记录、SSL 证书和 DDNS 的交互式 Bash 工具。

## 功能

### DNS 记录管理
- 列出所有 DNS 域名
- 查询指定域名的 DNS 记录
- 创建 / 更新 / 删除 DNS 记录（支持 A、AAAA、MX、CNAME、TXT、NS）

### DDNS 动态 IP 更新
- 一键 DDNS 更新，自动检测公网 IP
- 支持 A (IPv4) 和 AAAA (IPv6) 记录

### 证书管理
- 查询证书状态与到期时间
- 下载证书（fullchain / cert / privkey / bundle）
- 发起证书续签

### 交互体验
- 彩色终端界面，结构化菜单
- 表格化数据展示
- 输入验证与安全确认
- CLI 模式支持脚本化调用与 crontab

## 快速开始

```bash
curl -O https://raw.githubusercontent.com/UIMAK/vps8_dns_manager/main/vps8-dns-manager.sh
chmod +x vps8-dns-manager.sh
bash vps8-dns-manager.sh
```

首次运行会提示配置 API Key（在 [vps8 个人资料页](https://vps8.zz.cd/client/profile) 获取）。

## 使用方式

### 交互模式（默认）

直接运行脚本，通过数字菜单选择操作：

```bash
bash vps8-dns-manager.sh
```

### CLI 模式

适合脚本调用或 crontab：

```bash
# DNS 管理
bash vps8-dns-manager.sh domains                          # 列出域名
bash vps8-dns-manager.sh records example.com              # 查询记录
bash vps8-dns-manager.sh create example.com www A 1.2.3.4 600  # 创建记录
bash vps8-dns-manager.sh update example.com 12345 5.6.7.8 600  # 更新记录
bash vps8-dns-manager.sh delete example.com 12345         # 删除记录

# DDNS
bash vps8-dns-manager.sh ddns example.com A               # 自动检测IP
bash vps8-dns-manager.sh ddns example.com A 203.0.113.5   # 指定IP

# 证书管理
bash vps8-dns-manager.sh cert-list example.com            # 查询证书
bash vps8-dns-manager.sh cert-download example.com fullchain  # 下载证书
bash vps8-dns-manager.sh cert-renew example.com           # 续签证书

# 设置
bash vps8-dns-manager.sh set-key YOUR_API_KEY             # 配置 API Key
bash vps8-dns-manager.sh help                             # 帮助
```

### DDNS 定时任务

```bash
# 每 5 分钟更新一次 DDNS
*/5 * * * * /path/to/vps8-dns-manager.sh ddns example.com A
```

## 配置文件

配置保存在 `~/.vps8-dns-manager/config`（权限 600）：

```
API_KEY=your_api_key_here
```

证书下载保存至脚本目录下的 `certs/<域名>/` 文件夹。

## 依赖

- `bash` ≥ 4.0
- `curl`
- `grep` / `sed` / `awk`（兼容 GNU、BusyBox、BSD）

无需安装 `jq` 或 `python3`，JSON 解析完全内置。

## 支持的系统

| 发行版 | 状态 |
|--------|------|
| Debian / Ubuntu | ✅ |
| CentOS / RHEL / Fedora | ✅ |
| Alpine Linux | ✅ (需 bash) |
| Arch Linux | ✅ |
| openSUSE | ✅ |
| macOS | ✅ |

## API 参考

| 接口 | 用途 |
|------|------|
| `POST /api/client/dnsopenapi/domain_list` | 列出 DNS 域名 |
| `POST /api/client/dnsopenapi/record_list` | 列出 DNS 记录 |
| `POST /api/client/dnsopenapi/record_create` | 创建 DNS 记录 |
| `POST /api/client/dnsopenapi/record_update` | 更新 DNS 记录 |
| `POST /api/client/dnsopenapi/record_delete` | 删除 DNS 记录 |
| `POST /api/client/certcenter/list` | 查询证书 |
| `POST /api/client/certcenter/download` | 下载证书 |
| `POST /api/client/certcenter/renew` | 续签证书 |
| `POST /api/client/servicedns/ddns_update` | DDNS 更新 |

认证方式：HTTP Basic Auth (`client` : `API_KEY`)

## 相关链接

- 官网: https://vps8.zz.cd
- 状态页: https://status.i8.al/status/vps8

## License

MIT
