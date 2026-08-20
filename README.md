# 项目简介

本固件适配斐讯 N1，定位**轻量旁路由**，不含 PPPoE、WiFi 相关功能。预置了旁路由常用服务集，但代理节点/订阅、服务配置等私有数据仍留给刷机后自行配置。

固件预置的 luci-app 与服务：

- [luci-app-amlogic](https://github.com/ophub/luci-app-amlogic)：系统更新、内核更新、CPU 调频等
- PassWall（luci-app-passwall，内核 sing-box/xray-core）：代理分流
- AdGuardHome：DNS 过滤
- SNMP（snmpd）：监控
- KMS（vlmcsd）：激活服务

首启会通过 `etc/uci-defaults/99-bypass-router` 自动完成旁路由基础设置：关闭 DHCP/DHCPv6、开启 IPv4 转发、启用软件流量卸载（S905D 无硬件 offload，硬件卸载与 fullcone NAT 均关闭以免 firewall4 加载失败）、设置时区（Asia/Shanghai）与国内 NTP 服务器。

LAN 默认地址 `192.168.0.4/24`，网关 `192.168.0.1`（可按需在 `armsr/armv8/N1/files/etc/config/network` 调整）。

## 本地构建

在仓库根目录直接执行：

```bash
./bin/build.sh
```

脚本会克隆 ImmortalWrt、跑 `diy.sh`、铺上 N1 的 overlay/config 并编译，产物默认输出到原生盘：

```bash
/opt/openwrt-build/output/bin/targets/armsr/armv8/
```

> **构建目录必须落在原生文件系统上。** OpenWrt 编译树有大量并行小文件写入，在 virtiofs/macOS 挂载点上会损坏（perl/ncurses 等 host 工具随机构建失败）。脚本默认把编译树、缓存和产物都放在 `/opt/openwrt-build`（`BUILD_ROOT`），仓库本身留在原处不受污染。想把产物取回仓库时用 `ARTIFACT_DIR=./output ./bin/build.sh` 覆盖即可。

重复执行即可重新生成镜像。构建缓存（源码下载 `dl/`、feeds、ccache）都在 `BUILD_ROOT/cache` 下，重复构建会复用。

前置依赖（Ubuntu/Debian）—— 与 CI 共用同一个脚本 `bin/build-deps.sh`：

```bash
sudo ./bin/build-deps.sh
```

另需一份预编译 Go 作为外部 bootstrap（OpenWrt Go ≥1.26 需要 ≥1.24.6 的 bootstrap，arm64 上不能从源码起），装到 `/usr/local/go-bootstrap`（`GO_BOOTSTRAP`）。脚本检测不到时会打印安装命令。

常用覆盖项：

```bash
BUILD_ROOT=/mnt/ssd/owrt ./bin/build.sh          # 换构建盘
ARTIFACT_DIR=./output ./bin/build.sh              # 产物取回仓库
ALL_PROXY=socks5h://127.0.0.1:1080 ./bin/build.sh # 换代理
JOBS=4 ./bin/build.sh                             # 限并发
```

> 默认所有出站请求走 `socks5h://192.168.0.8:1180` 代理，代理地址不同时用 `ALL_PROXY` 覆盖即可。

***

# 致谢

本项目基于 [ImmortalWrt-25.12](https://github.com/immortalwrt/immortalwrt/tree/openwrt-25.12) 源码编译，使用 ophub 的[脚本](https://github.com/ophub/amlogic-s9xxx-openwrt)和 flippy 的[内核](https://github.com/ophub/kernel/releases/tag/kernel_flippy)打包成完整固件，感谢开发者们的无私分享。<br>
flippy 固件的更多细节参考[恩山论坛帖子](https://www.right.com.cn/forum/thread-4076037-1-1.html)。
