# 项目解剖报告 -- school_ruijie

---

## 1. 一句话白话总结

这是一个运行在斐讯N1路由器(iStoreOS/OpenWrt)上的**锐捷ePortal校园网自动登录+保活重连脚本**，解决的核心问题是：校园网需要Web认证才能上网，每次掉线或断电重启后需要手动重新登录，此脚本实现全自动认证、掉线检测与重连，做到"来电即上网，无人值守"。

---

## 2. 全景架构与模块关系

### 2.1 目录树结构

```
\trae项目\school_ruijie/
  |-- .gitignore          # Git忽略规则
  |-- LICENSE             # GPL v3 开源协议
  |-- README.MD           # 项目说明文档
  |-- ghulogin.sh         # 核心脚本（唯一业务代码，899行）
```

项目极其精简，只有一个核心Shell脚本文件，无其他源码文件、无依赖管理文件、无构建系统。

### 2.2 关键核心文件

| 文件 | 角色 |
|------|------|
| [ghulogin.sh](file:///trae项目/school_ruijie/ghulogin.sh) | **唯一核心文件**。包含全部业务逻辑：认证登录、RSA加密、保活重连、配置管理、系统服务安装、在线更新、交互式菜单、日志系统。899行单文件Shell脚本，是整个项目的"一切"。 |
| [README.MD](file:///trae项目/school_ruijie/README.MD) | 项目使用说明文档，包含安装、配置、命令行用法。 |
| [.gitignore](file:///trae项目/school_ruijie/.gitignore) | 忽略规则，排除了APP_SPEC.json、login.md、编辑器临时文件等。 |

### 2.3 数据流图

```
用户执行 qhulogin <命令>
        |
        v
  +-- main() --+                    系统路径:
  |  命令路由    |                    /etc/qhulogin/qhulogin.conf  (配置)
  +-----+------+                    /var/log/qhulogin.log        (日志)
        |                           /var/run/qhulogin.pid        (PID)
        |                           /etc/qhulogin/.login_cache   (URL缓存)
        +----> do_login()  <----------- 核心认证流程
        |         |
        |         +-- load_config()  <--- 读取配置文件
        |         +-- check_online() <--- HTTP 204检测是否在线
        |         +-- curl 204页面  <--- 被重定向到认证页
        |         |       |
        |         |       +-- 提取login_page_url (5种正则策略)
        |         |       +-- 缓存URL到 .login_cache
        |         |
        |         +-- 构造InterFace.do?method=login URL
        |         +-- 获取RSA公钥 --> rsa_encrypt_password()
        |         |       |
        |         |       +-- openssl rsautl -encrypt 加密密码
        |         |
        |         +-- curl POST 认证请求 (userId/password/service/queryString)
        |         +-- 解析结果 (success/fail/多设备上限)
        |
        +----> do_keepalive()  <------ 保活守护进程
        |         |
        |         +-- 初始认证 (重试30次, 退避5s/120s)
        |         +-- 无限循环: sleep(interval) --> check_online()
        |         |       |
        |         |       +-- 在线 --> continue
        |         |       +-- 离线 --> do_login() + 退避重试
        |
        +----> do_config()     <------ 交互式配置 (学号/密码/运营商)
        +----> do_logout()     <------ 登出 (获取userIndex踢出会话)
        +----> do_status()     <------ 状态面板 (在线/配置/PID/自启/日志)
        +----> do_logs()       <------ 查看最近50条日志
        +----> do_install()    <------ 安装到系统 + 创建procd服务
        +----> do_uninstall()  <------ 卸载
        +----> do_update()     <------ 从GitHub在线更新 (直连+镜像源)
        +----> show_menu()     <------ 交互式菜单 (11个选项)
```

---

## 3. 底层技术栈与依赖

### 3.1 核心语言

- **Shell (POSIX sh)** -- 使用 `#!/bin/sh` 解释器，兼容 busybox ash，严格模式 `set -u`
- 版本: 1.2.0

### 3.2 目标运行平台

- **iStoreOS / OpenWrt** (嵌入式Linux路由器系统)
- 硬件: 斐讯N1

### 3.3 系统依赖

| 依赖 | 用途 | 是否必需 |
|------|------|---------|
| `curl` | HTTP请求(认证、在线检测、更新下载) | 必需 |
| `openssl` (rsautl) | RSA公钥加密密码 | 可选(失败回退明文) |
| `xxd` | 将加密结果转为十六进制 | RSA加密时需要 |
| `route` | 获取默认网关IP | 降级时需要 |
| `md5sum` | 更新时文件校验 | 更新功能需要 |
| `procd` (OpenWrt服务管理) | 进程守护与开机自启 | 安装服务时需要 |
| `stty` | 交互式配置时隐藏密码输入 | 配置功能需要 |

> 以上工具在 iStoreOS/OpenWrt 中均自带，无需额外安装。

### 3.4 运营商编码映射

脚本内置了四种运营商的URL编码值(双重编码 `%25` 前缀):

| 变量 | 值 | 含义 |
|------|-----|------|
| `CAMPUS` | `%25E6%25A0%25A1%25E5%259B%25AD%25E7%25BD%2591` | 校园网 |
| `UNICOM` | `%25E6%25A0%25A1%25E5%259B%25AD%25E8%2581%2594%25E9%2580%259A` | 校园联通 |
| `TELECOM` | `%25E6%25A0%25A1%25E5%259B%25AD%25E7%2594%25B5%25E4%25BF%25A1` | 校园电信 |
| `MOBILE` | `%25E6%25A0%25A1%25E5%259B%25AD%25E7%25A7%25BB%25E5%258A%25A8` | 校园移动 |

---

## 4. 如何运行此项目

### 4.1 部署方式

此项目设计为在OpenWrt路由器上运行，不是在普通PC上运行。部署步骤如下:

```bash
# 1. 从GitHub下载脚本到路由器
curl -o qhulogin.sh https://raw.githubusercontent.com/stilesloveland-cyber/school_ruijie/master/ghulogin.sh

# 2. 安装到系统 (自动创建 /usr/bin/qhulogin + /etc/init.d/qhulogin 服务)
sh qhulogin.sh install

# 3. 交互式配置账号
qhulogin config
# 按提示输入: 学号、密码、选择运营商

# 4. 启动保活服务
/etc/init.d/qhulogin start
/etc/init.d/qhulogin enable   # 开机自启
```

### 4.2 环境变量 / 配置文件

配置文件路径: `/etc/qhulogin/qhulogin.conf`

```bash
USERNAME="学号"
PASSWORD="密码"
SERVICE="campus"          # campus / unicom / telecom / mobile
PING_INTERVAL="30"        # 保活检测间隔(秒)
```

无需 .env 文件，所有配置通过 `qhulogin config` 交互式写入。

### 4.3 运行时产生的文件

| 路径 | 用途 |
|------|------|
| `/etc/qhulogin/qhulogin.conf` | 配置文件 (权限600) |
| `/etc/qhulogin/.login_cache` | 认证URL缓存 |
| `/var/log/qhulogin.log` | 运行日志 (超100KB自动轮转) |
| `/var/run/qhulogin.pid` | 保活进程PID |
| `/etc/init.d/qhulogin` | procd服务脚本 |
| `/usr/bin/qhulogin` | 全局命令 |

### 4.4 命令行用法

```bash
qhulogin              # 交互式菜单
qhulogin login        # 立即认证
qhulogin relogin      # 强制重新认证
qhulogin logout       # 登出
qhulogin status       # 查看状态
qhulogin logs         # 查看日志
qhulogin config       # 配置账号
qhulogin keepalive    # 启动保活(前台)
qhulogin install      # 安装到系统
qhulogin uninstall    # 卸载
qhulogin update       # 检查并安装更新
```

---

## 5. 潜在隐患与代码质量评估

### 5.1 代码质量亮点

- **结构清晰**: 单文件但分区明确，用 `#====` 注释块划分功能模块，可读性好
- **防御性编程**: `set -u` 严格模式，大量 `2>/dev/null` 静默错误，`:-` 默认值保护
- **日志系统完善**: 分级日志(INFO/SUCCESS/WARN/ERROR/DEBUG)，自动轮转(100KB截断保留200行)
- **RSA加密支持**: 自动获取公钥加密密码，失败优雅降级到明文
- **多策略URL提取**: 认证页URL提取有5种正则回退策略，健壮性较高
- **URL缓存机制**: 首次成功后缓存认证URL，避免重复探测
- **更新机制安全**: 下载后校验shebang、语法检查、MD5对比、备份回滚

### 5.2 潜在隐患与问题

#### (1) 安全风险

- **密码明文存储**: 配置文件 `/etc/qhulogin/qhulogin.conf` 中密码以明文保存，虽然 `chmod 600`，但root用户仍可直接读取。建议考虑base64混淆或简单加密。
- **RSA公钥临时文件**: [ghulogin.sh:138-141](file:///trae项目/school_ruijie/ghulogin.sh#L138-L141) 将公钥写入 `/tmp/qhulogin_pubkey.pem`，/tmp目录其他用户可能可读。
- **明文密码回退**: RSA加密失败时回退到明文传输密码([ghulogin.sh:336-339](file:///trae项目/school_ruijie/ghulogin.sh#L336-L339))，在校园网环境下存在中间人风险。

#### (2) 健壮性问题

- **保活进程无看门狗**: `do_keepalive()` 是纯Shell循环，如果脚本本身异常退出(如OOM kill)，没有外部机制重启。虽然安装了procd服务，但 `keepalive` 命令是前台运行模式，不通过procd管理。
- **日志轮转竞态**: [ghulogin.sh:53-61](file:///trae项目/school_ruijie/ghulogin.sh#L53-L61) 日志轮转使用 `tail > tmp && mv`，在并发写入时可能丢失日志。
- **PID文件过期**: [ghulogin.sh:398](file:///trae项目/school_ruijie/ghulogin.sh#L398) `echo $$ > PID_FILE` 在保活模式写入PID，但如果进程被kill后PID被系统回收，`kill -0` 检测可能误判。
- **交互式菜单状态检测**: [ghulogin.sh:787-800](file:///trae项目/school_ruijie/ghulogin.sh#L787-L800) 后台检测状态写入 `/tmp/qhulogin_status`，首次运行时文件不存在会显示"检测中"，且存在竞态读取问题。

#### (3) 代码风格问题

- **文件名不一致**: 脚本内部注释和函数名使用 `qhulogin`，但文件名为 `ghulogin.sh`，README标题也是 `qhulogin`，存在命名不一致(GHU vs QHU)。
- **Git提交信息无意义**: 查看git历史，提交信息均为 "1231"、"124124"、"3123123" 等无意义字符串，完全无法追溯变更历史。
- **硬编码运营商编码**: [ghulogin.sh:38-41](file:///trae项目/school_ruijie/ghulogin.sh#L38-L41) 运营商的URL编码值硬编码在脚本中，如果学校更换认证系统或运营商名称变化，需要手动修改脚本。
- **User-Agent硬编码**: [ghulogin.sh:351](file:///trae项目/school_ruijie/ghulogin.sh#L351) Chrome版本号 `149.0.0.0` 硬编码，随时间推移可能被认证服务器识别为过时浏览器。
- **更新源硬编码**: [ghulogin.sh:654-655](file:///trae项目/school_ruijie/ghulogin.sh#L654-L655) GitHub仓库地址硬编码，如果仓库迁移则更新功能失效。

#### (4) 功能局限

- **仅支持锐捷ePortal**: 认证协议完全针对锐捷ePortal的 `InterFace.do?method=login` 接口，不兼容其他认证系统(如城市热点、深澜等)。
- **无多账号支持**: 只能配置一个账号，无法实现多设备/多账号切换。
- **无网络变化检测**: 仅通过HTTP 204检测在线状态，不监听网络接口事件(如WAN口重连)，检测延迟取决于PING_INTERVAL。

### 5.3 如果要添加新功能，需要注意的"雷区"

1. **修改认证流程时**: `do_login()` 函数([ghulogin.sh:220-382](file:///trae项目/school_ruijie/ghulogin.sh#L220-L382))是最核心也最脆弱的部分，URL提取的5种策略顺序不能随意调整，queryString的二次URL编码逻辑(`%2526`/`%253D`)是锐捷ePortal的特殊要求，修改可能导致认证失败。

2. **修改保活逻辑时**: `do_keepalive()` 中的退避策略(普通5s/10s，多设备冲突120s)是经过实践验证的，过快的重试可能触发认证服务器的频率限制。

3. **添加多账号功能时**: 当前配置文件格式是简单的Shell变量赋值(`. "$CONF_FILE"` 直接source)，如果要支持多账号，需要重新设计配置文件格式和加载机制，同时注意向后兼容。

4. **跨平台适配时**: 脚本使用了多个busybox/OpenWrt特有命令(`procd`、`rc.common`、`route -n`)，如果要移植到其他Linux发行版，需要替换服务管理方案和网络检测方式。

5. **修改更新机制时**: `do_update()` 中的MD5对比和语法检查(`sh -n`)是安全防线，不要移除这些校验步骤。

---

## 附录: 核心函数清单

| 函数名 | 行号 | 功能 |
|--------|------|------|
| `log_msg()` | L46 | 写入日志文件(带轮转) |
| `print_info/success/warn/error/debug()` | L63-67 | 带颜色的控制台输出+日志 |
| `load_config()` | L72 | 加载配置文件(source方式) |
| `save_config()` | L80 | 保存配置到文件 |
| `get_service_string()` | L94 | 运营商名称 -> URL编码值 |
| `check_online()` | L117 | HTTP 204检测网络连通性 |
| `rsa_encrypt_password()` | L133 | RSA公钥加密密码 |
| `do_logout()` | L159 | 登出(踢出旧会话) |
| `do_login()` | L220 | 核心认证流程 |
| `do_keepalive()` | L387 | 保活守护进程(无限循环) |
| `do_status()` | L459 | 状态面板展示 |
| `do_logs()` | L512 | 查看日志(带颜色) |
| `do_config()` | L531 | 交互式配置 |
| `do_install()` | L581 | 安装到系统+创建procd服务 |
| `do_uninstall()` | L630 | 卸载 |
| `do_update()` | L653 | 在线更新(直连+镜像源) |
| `do_service_ctrl()` | L760 | 服务管理(start/stop/restart/enable/disable) |
| `show_menu()` | L778 | 交互式菜单(11选项) |
| `show_help()` | L841 | 帮助信息 |
| `main()` | L869 | 主入口(命令路由) |

---

[项目扫描完毕] 大 Boss，该项目的底细已被彻底摸清，请您审阅！
