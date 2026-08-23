# 项目简介

本固件定位**轻量旁路由**，预置了旁路由常用服务集，但代理节点/订阅、服务配置等私有数据仍留给刷机后自行配置。目前提供三种构建目标（profile）：

- **N1**（`armsr/armv8/N1`）：斐讯 N1（Amlogic S905D），经 ophub/flippy 打包为可刷写的 `*.img.gz`，含 [luci-app-amlogic](https://github.com/ophub/luci-app-amlogic)（晶晨宝盒）在线升级；板载 WiFi 默认开放 AP `N1-OpenWrt` 桥接进 LAN。
- **x86**（`x86/64`）：x86/64 通用机型（软路由/虚拟机），OpenWrt 直接产出可 UEFI 引导的 combined-efi 镜像，无需 ophub 二次打包，也不含 luci-app-amlogic。
- **armvirt**（`armsr/armv8/armvirt`）：ARM64 通用虚拟机（Apple Silicon 上的 UTM/QEMU，或任意 EDK2/UEFI aarch64 hypervisor）。与 N1 同 `armsr/armv8` target，但走 x86 那套流程直接产出可 UEFI 引导的 combined-efi 镜像（无 ophub、无 amlogic、无板载 WiFi，物理网卡 kmod 换 virtio）。

三种 profile 共享同一套旁路由服务与 overlay（见 `common/`），只有 target/rootfs/打包流程不同。

固件预置的 luci-app 与服务：

- PassWall（luci-app-passwall，内核 sing-box/xray-core）：代理分流，默认 **GFW 列表**模式（仅墙外域名走代理，国内及未命中的直连）
- AdGuardHome：DNS 过滤
- SNMP（snmpd）：监控
- KMS（vlmcsd）：激活服务
- EasyTier（luci-app-easytier）：异地组网（节点名/密钥等敏感信息留刷机后在 LuCI 配置）
- （仅 N1）luci-app-amlogic：系统更新、内核更新、CPU 调频等

首启会通过 `etc/uci-defaults/99-bypass-router` 自动完成旁路由基础设置：关闭 DHCP/DHCPv6、开启 IPv4 转发、启用软件流量卸载（S905D 无硬件 offload，硬件卸载与 fullcone NAT 均关闭以免 firewall4 加载失败）、设置时区（Asia/Shanghai）与国内 NTP 服务器。amlogic 配置、LAN masquerade 等按设备差异的项，均按是否存在 `/etc/config/amlogic`（仅 N1 有）自动判定，x86/armvirt 上自动处理。

AdGuardHome 预置为旁路由场景做了三项 DNS 调整（`common/files/etc/adguardhome/adguardhome.yaml`）：禁 AAAA/IPv6 解析（`aaaa_disabled`，避免客户端走 IPv6 直连绕过 PassWall）、关 DNSSEC 验签（`enable_dnssec: false`，上游国内 DNS 分流多不透传 DNSSEC，开了会解析失败）、拦截模式设为空 IP（`blocking_mode: null_ip`，被拦域名返回 `0.0.0.0`/`::` 直接让连接失败）。

LAN 默认地址 `192.168.0.4/24`，网关 `192.168.0.1`（可按需在 `common/files/etc/config/network` 调整，两 profile 共用）。

## 本地构建

在仓库根目录直接执行（`bin/build.sh` 是入口，按 profile 分发到 `bin/build-N1.sh` / `bin/build-x86.sh` / `bin/build-armvirt.sh`）：

```bash
./bin/build.sh          # 不带参数：依次构建 N1、x86、armvirt（三个）
./bin/build.sh N1       # 只构建斐讯 N1（Amlogic S905D）
./bin/build.sh x86      # 只构建 x86/64 EFI
./bin/build.sh armvirt  # 只构建 ARM64 虚拟机 EFI（UTM/QEMU）
```

> 每个 profile 都是独立的 20-30G / 完整 `make`，一起跑时间和磁盘成倍增长。x86、armvirt 各用独立 scratch 子树（`build-x86`/`feeds-x86`/`ccache-x86`、`build-armvirt`/…），跟 N1 共存不冲突。N1 构建失败会中止、不再跑后续 profile。

脚本会克隆 ImmortalWrt、跑对应的 `diy.sh`、铺上共享 overlay + profile 的 config 并编译。N1 产物在编译后经 ophub 打包为 `*.img.gz`；x86、armvirt 直接产出可引导的 `*-generic-squashfs-combined-efi.img.gz`。

**最终可刷写镜像**（三个 profile 都）落到仓库根的 `dist/`（已 git-ignore）：N1 由 `package.sh` 移入，x86/armvirt 的 combined-efi 由各自的 `build-*.sh` 拷入。两者都会重命名为统一格式 `immortalwrt_<op版本>_<平台>_k<内核号>_<日期>_<时间>.img.gz`（`<时间>` 为 `HHMMSS`，精确到秒）：

```
N1:      immortalwrt_25.12_s905d_k6.12.48_2026.08.21_143005.img.gz
x86:     immortalwrt_25.12_x86_64_k6.12.103_2026.08.21_143005.img.gz
armvirt: immortalwrt_25.12_armv8_k6.12.103_2026.08.21_143005.img.gz
```

同一次构建的三个 profile 共用同一个时间戳（CI 里在 `setup` 阶段统一生成，本地各脚本自行生成），GitHub release 的 tag（`firmware_<日期>_<时间>`）也精确到秒，因此每次构建都是独立、不覆盖的 release。

N1 保留 `s905d_k6.12.NN` 段供晶晨宝盒 OTA 识别（内核为 ophub/flippy 版），x86/armvirt 内核号取自编译产物 `.manifest`（ImmortalWrt 官方编译），与 N1 内核不同源。完整的中间产物（整个 `bin/targets`）另外输出到原生盘：

```bash
/opt/openwrt-build/output/bin/targets/armsr/armv8/   # N1 / armvirt 中间产物
/opt/openwrt-build/output/bin/targets/x86/64/        # x86 中间产物
```

> **构建目录必须落在原生文件系统上。** OpenWrt 编译树有大量并行小文件写入，在 virtiofs/macOS 挂载点上会损坏（perl/ncurses 等 host 工具随机构建失败）。脚本默认把编译树、缓存和产物都放在 `/opt/openwrt-build`（`BUILD_ROOT`），仓库本身留在原处不受污染。想把产物取回仓库时用 `ARTIFACT_DIR=./output ./bin/build.sh` 覆盖即可。

重复执行即可重新生成镜像。构建缓存（源码下载 `dl/`、feeds、ccache）都在 `BUILD_ROOT/cache` 下，重复构建会复用。

前置依赖（Ubuntu/Debian）—— 与 CI 共用同一个脚本 `bin/build-deps.sh`：

```bash
sudo ./bin/build-deps.sh
```

**N1 和 armvirt 另需**一份预编译 Go 作为外部 bootstrap（OpenWrt Go ≥1.26 需要 ≥1.24.6 的 bootstrap，本地 arm64 host 上不能从源码起），装到 `/usr/local/go-bootstrap`（`GO_BOOTSTRAP`）。脚本检测不到时会打印安装命令。x86 可从源码起 Go，`GO_BOOTSTRAP` 存在则复用、缺失也不强制。（CI 用 x86_64 runner 交叉编译，能从源码起 Go，故无需 bootstrap。）

常用覆盖项（对两个 profile 通用）：

```bash
BUILD_ROOT=/mnt/ssd/owrt ./bin/build.sh x86       # 换构建盘
ARTIFACT_DIR=./output ./bin/build.sh x86          # 产物取回仓库
ALL_PROXY=socks5h://127.0.0.1:1080 ./bin/build.sh # 换代理
JOBS=4 ./bin/build.sh                             # 限并发
```

> 默认所有出站请求走 `socks5h://192.168.0.8:1180` 代理，代理地址不同时用 `ALL_PROXY` 覆盖即可。

***

# 致谢

本项目基于 [ImmortalWrt-25.12](https://github.com/immortalwrt/immortalwrt/tree/openwrt-25.12) 源码编译。N1 使用 ophub 的[脚本](https://github.com/ophub/amlogic-s9xxx-openwrt)和 flippy 的[内核](https://github.com/ophub/kernel/releases/tag/kernel_flippy)打包为可刷写固件；x86、armvirt 由 OpenWrt 官方直接产出 EFI 镜像。感谢开发者们的无私分享。<br>
flippy 固件（N1）的更多细节参考[恩山论坛帖子](https://www.right.com.cn/forum/thread-4076037-1-1.html)。
