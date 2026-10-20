# ⚠️ 最终状态（2026-10-20）

本项目已**停止日常使用**并发布最终版本 v1.1.0。最终配置为「HWUI GL + SurfaceFlinger
Vulkan（skiavkthreaded）」；由于 ColorOS/Skia 对厂商 10-bit AHB（format 4096）的
Vulkan 包装缺陷（`Invalid GrBackendFormat` → abort），HWUI Vulkan 不可用。
回滚：在 KernelSU 管理器禁用 `MTK_D8100_Vulkan1.4.Panvk` 与 `hwui_use_vulkan` 后重启。
完整结论见仓库 `docs/FINAL-REPORT.md`。

# PanVK WSI7 global-enable module

把固定构建的 **PanVK WSI7**（Mesa 26.3 + 补丁 019–030）作为 64 位 Vulkan HAL 临时
替换到系统路径的 KernelSU 模块。默认 **关闭**（系统继续用原厂 Vulkan）；通过 Root
管理器的「操作」按钮切换下次启动是否全局启用。

- 只替换 64 位 Vulkan ICD：`/vendor/lib64/hw/mt6895/vulkan.mali.so`
- ColorX 兼容副本在**设备本机**由原厂库生成（字节补丁放在 `common.sh`），
  安装包**不分发任何 OEM 二进制**；原厂库哈希不匹配则拒绝启用
- OpenGL/EGL、32 位 Vulkan 与 SurfaceFlinger 合成后端（`skiagl`）保持原厂
- 不写入 vendor 分区；挂载均为运行时 bind mount，重启即恢复原厂

## 作用范围（scope）

- `scope=apps`（默认，推荐）：驱动与 ColorX 兼容副本只绑定进**应用孵化命名空间**
  （zygote / webview_zygote / usap），新启动的应用使用 PanVK；SurfaceFlinger、
  system_server 等系统进程保留原厂驱动。
- `scope=system`（实验，不推荐）：在 post-fs-data 绑定到 init 命名空间，**包括
  SurfaceFlinger**。2026-10-17 实测：解锁界面合成 10-bit 压缩视频（format 54 /
  usage 0x400900 / 1272×2772）时 SurfaceFlinger 在 `GaneshBackendTexture` abort
  （`Failed to create a valid texture`，SF 进程内为 wsi7 BuildId `3473fa02…`），
  随后软重启。需要该组合时请改用 apps scope。

## 安装与启用

1. Root 管理器安装本模块 ZIP，**重启**（此时仍是原厂 Vulkan）；
2. 打开模块的「操作」按钮：把 `enable_global` 从 0 切到 1；
3. 再重启：service 阶段等待 zygote/usap 出现后绑定驱动，并核对
   SurfaceFlinger 命名空间仍为原厂；
4. 确认生效：在**任意新启动的应用**内 `cat /proc/self/maps | grep vulkan.mali`
   可见；系统进程仍为 OEM。日志：
   `/data/adb/modules/MTK_D8100_Vulkan1.4.Panvk/log.txt`。

## 关闭 / 回滚

- 再按一次「操作」按钮切回 0 并重启；或
- 在 Root 管理器禁用模块并重启；或
- 删除 `/data/adb/modules/MTK_D8100_Vulkan1.4.Panvk` 后重启。

## 失败安全

- `post-fs-data.sh` 统计未成功开机的次数；**连续 3 次**没有看到
  `sys.boot_completed=1` 时，自动把 `enable_global` 改回 0（下一次启动恢复原厂）；
- `service.sh` 在 `boot_completed=1` 后写 `boot-ok`，成功启动会重置计数；
- 日志：`/data/adb/modules/MTK_D8100_Vulkan1.4.Panvk/log.txt`。

## 已验证范围（2026-10-17，PGKM10 / Android 17）

- 冷启动 3 次全部成功（`boot_completed` 28–32 秒），失败安全计数逻辑验证；
- 微信 8.0.79：公众号/服务号 Flutter 页与文章 WebView 页正常；此前可稳定复现的
  「打开公众号卡死」在 `acq.replay=1` 下消失（同驱动 A/B 对照）；
- 星穹铁道不再触发 ColorX `constructFragmentShadingRatesInfo` 崩溃（仅验证到登录 SDK 界面）；
- 相机预览、Quetta 浏览器、系统设置渲染正常；约 13 分钟浸泡无 ANR/tombstone；
- 驱动微基准：提交延迟比 OEM 低 26–31%，清屏吞吐高 30–46%；
- 微信冷启动中位数 685 ms（OEM 909 ms）。

## 已知限制

- **不要使用 `scope=system`**：解锁界面遇到 10-bit 压缩视频（P010/YU10）时
  SurfaceFlinger 会 abort 并软重启（2026-10-17 实机 tombstones 已定位）；
- SurfaceFlinger 始终使用原厂 GLES 合成；把 `debug.renderengine.backend` 改为
  `skiavk` 仍会因压缩 YU10 导入失败而崩溃；
- 游戏只验证到登录界面，实际画面/长时间游戏未验证；
- 仅供本人设备实验使用；刷机/模块操作有风险，请保留可回滚手段。

## 版本状态（v1.0.0，2026-10-17）

- 稳定版：驱动 sha256 `e62177fb…`（含 019–034 补丁），模块 versionCode 10；
- 已修复：SystemUI `GPU_SHAREABILITY_FAULT`（GPU 非缓存导入）、微信 acquire 路径无界等待；
- 已验证：重启自动挂载、锁屏/通知栏 200 秒压力 0 fault、15 分钟稳定、性能无回退；
- 开关：`enable_global=1` + `scope=system` + `hwui_use_vulkan`（其
  `debug.renderengine.backend` 必须是 `skiagl`）；
- **`skiavkthreaded` 暂不支持**（压缩 YU10 的 Vulkan 导入缺失），计划在下一个测试版
  `1.1.0-beta1` 补齐，详见 `docs/BETA-SKIAVKTHREADED-PLAN.md`；
- 回滚：禁用 `MTK_D8100_Vulkan1.4.Panvk` 与 `hwui_use_vulkan` 后重启。

## 永久启用 skiavkthreaded（2026-10-18 验证）

本机已验证 `skiavkthreaded` + HWUI Vulkan + YU10 导入可用（SF `RE Vulkan
(Ganesh)`、`Vulkan device initialized: 1`、SystemUI/launcher/Settings 均映射
Vulkan、`Pipeline=Skia (Vulkan)`）。

启用步骤（需 038 驱动 payload）：

1. 驱动模块：`enable_global=1`、`scope=system`，payload 为 038（本 beta ZIP）；
2. `hwui_use_vulkan` 模块启用，`system.prop`：
   `debug.renderengine.backend=skiavkthreaded`、
   `debug.renderengine.vulkan=true`、`debug.hwui.renderer=skiavk`、
   `ro.hwui.use_vulkan=true`；
3. 重启。

模块自带**运行时看门狗**（`service.sh`）：若 SurfaceFlinger 在 10 分钟内重启
≥3 次，自动把配置回退为 `skiagl`、禁用 `hwui_use_vulkan` 并重启，防止崩溃循环。

一键回滚：禁用 `hwui_use_vulkan`（或把 `debug.renderengine.backend` 改为
`skiagl`、`debug.renderengine.vulkan=false`）后重启。
