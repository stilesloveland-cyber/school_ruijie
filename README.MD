# ghulogin

锐捷 ePortal Web 认证自动登录工具，运行于斐讯N1 (iStoreOS/OpenWrt)。

自动认证 + Ping保活 + 断电来电自动重连，无需人工干预。

## 依赖

- curl
- openssl (RSA加密，可选)
- ping

> iStoreOS/OpenWrt 均自带以上工具，无需额外安装。

## 安装

```bash
# 从GitHub下载
curl -o ghulogin.sh https://raw.githubusercontent.com/stilesloveland-cyber/school_ruijie/master/ghulogin.sh

# 安装到系统
sh ghulogin.sh install
```

安装后自动创建：
- `/usr/bin/ghulogin` — 全局命令
- `/etc/init.d/ghulogin` — procd服务（崩溃自动重启）
- `/etc/ghulogin/ghulogin.conf` — 配置文件

## 使用

### 交互式菜单

```bash
ghulogin
```

### 命令行

```bash
ghulogin login       # 立即认证
ghulogin status      # 查看状态
ghulogin logs        # 查看日志
ghulogin config      # 配置账号
ghulogin keepalive   # 启动保活(前台)
ghulogin install     # 安装到系统
ghulogin uninstall   # 卸载
```

### 首次配置

```bash
ghulogin config
```

按提示输入学号、密码，选择运营商（校园网/校园联通/校园电信/校园移动）。

### 启动保活

```bash
/etc/init.d/ghulogin start    # 启动
/etc/init.d/ghulogin enable   # 开机自启
```

启动后每30秒Ping检测一次，断网自动重连，无限重试。

### 断电恢复

只要 `enable` 过一次，断电来电后 N1 开机即自动认证，无需任何操作。

## 配置文件

`/etc/ghulogin/ghulogin.conf`

```bash
USERNAME="学号"
PASSWORD="密码"
SERVICE="campus"          # campus/unicom/telecom/mobile
PING_HOST="180.101.50.188"
PING_INTERVAL="30"
```

## 卸载

```bash
ghulogin uninstall
```
