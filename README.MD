# qhulogin

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
curl -o qhulogin.sh https://raw.githubusercontent.com/stilesloveland-cyber/school_ruijie/master/qhulogin.sh

# 安装到系统
sh qhulogin.sh install
```

安装后自动创建：
- `/usr/bin/qhulogin` — 全局命令
- `/etc/init.d/qhulogin` — procd服务（崩溃自动重启）
- `/etc/qhulogin/qhulogin.conf` — 配置文件

## 使用

### 交互式菜单

```bash
qhulogin
```

### 命令行

```bash
qhulogin login       # 立即认证
qhulogin status      # 查看状态
qhulogin logs        # 查看日志
qhulogin config      # 配置账号
qhulogin keepalive   # 启动保活(前台)
qhulogin install     # 安装到系统
qhulogin uninstall   # 卸载
```

### 首次配置

```bash
qhulogin config
```

按提示输入学号、密码，选择运营商（校园网/校园联通/校园电信/校园移动）。

### 启动保活

```bash
/etc/init.d/qhulogin start    # 启动
/etc/init.d/qhulogin enable   # 开机自启
```

启动后每30秒Ping检测一次，断网自动重连，无限重试。

### 断电恢复

只要 `enable` 过一次，断电来电后 N1 开机即自动认证，无需任何操作。

## 配置文件

`/etc/qhulogin/qhulogin.conf`

```bash
USERNAME="学号"
PASSWORD="密码"
SERVICE="campus"          # campus/unicom/telecom/mobile
PING_HOST="180.101.50.188"
PING_INTERVAL="30"
```

## 卸载

```bash
qhulogin uninstall
```
