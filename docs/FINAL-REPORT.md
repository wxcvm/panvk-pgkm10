# PanVK WSI7 项目最终报告（FINAL，2026-10-20）

## 结论摘要

项目目标：为 OnePlus PGKM10（MTK MT6895 / Mali-G610 MC6 / Android 17）提供一套
可回滚的 PanVK 驱动与全局挂载，解决微信卡死、SystemUI 共享性故障，并尽可能提升
Vulkan 兼容性与性能，最后验证 SF `skiavkthreaded`。

**最终决定：停止在手机上使用 Vulkan 驱动模块，回到 OEM 渲染路径。
本仓库发布最终版本 v1.1.0，作为成果与结论归档。**

## 已完成并验证的成果

| 项目 | 结果 | 证据 |
|---|---|---|
| 微信卡死（acquire 路径无界等待） | 已修复 | 补丁 030 一次性 acquire 重放，`debug.mesa.movecert.acq.replay=true` |
| SystemUI 锁屏崩溃（`GPU_SHAREABILITY_FAULT`） | 已修复 | 补丁 034 GPU-uncached AHB 导入；200 s 锁屏/通知压力 0 fault |
| AFBC YU10（`DRM_FORMAT_YUV420_10BIT`）Vulkan 导入 | 探针全链路通过 | 补丁 035–038；properties/CreateImage/AllocateMemory/Bind/Conversion/CreateImageView 全成功 |
| SurfaceFlinger `skiavkthreaded`（RenderEngine Vulkan） | 验证可用 | `RE Vulkan (Ganesh)`、`Vulkan device initialized: 1`、YU10 层导入、0 fault |
| 应用侧 Vulkan 1.4 | 系统 loader 实测 1.4 | `loader_instance_version=1.4.0`、device apiVersion 1.4、186 个扩展；微信/vtools/SF 均映射驱动 |
| 稳定性/性能 | 正式版配置无回退 | 200 s 压力 0 fault；HWUI 性能 A/B p90 17 ms（非缓存） |

## 未解决 / 最终限制

1. **HWUI Vulkan（App UI 渲染）不可用**：ColorOS/Skia 的 Vulkan AHB 包装对厂商
   10-bit AHB（`AHardwareBuffer_Format==4096`）直接 `LOG_ALWAYS_FATAL`
   （`Invalid GrBackendFormat`），Settings 增强页与 Twitter 等 10-bit 视频应用闪退；
   OEM 驱动在同一路径表现为花屏。该问题位于闭源 HWUI/Skia，驱动/框架层均无法干净修复。
2. 因此最终配置为 **A**：HWUI 用 GL（`debug.hwui.renderer=skiagl`、
   `ro.hwui.use_vulkan=false`），SurfaceFlinger 保持 Vulkan（`skiavkthreaded` +
   `vulkan=true`）——显示正确、无闪退、无花屏。
3. 未覆盖：长时间游戏、10-bit HDR 视频播放、ColorOS 相机等高负载场景。

## 回滚（回到 OEM）

1. KernelSU 管理器禁用/卸载 `MTK_D8100_Vulkan1.4.Panvk` 与 `hwui_use_vulkan`；
2. 重启；`/vendor/lib64/hw/mt6895/vulkan.mali.so` 将恢复为 OEM 文件，
   `debug.renderengine.backend`/`debug.hwui.renderer` 恢复系统默认；
3. 本项目所有改动均在模块与 `/data`，不触碰 recovery，不丢用户数据。

## 产物

- 最终模块 ZIP：`PanVK-WSI7-PGKM10-v1.1.0.zip`（驱动 038，sha256
  `302232ed0407b8f173c73d4e5dd55461b9b9bbba1e02f7d0a98acd6c09d12d3a`）
- 历史版本：`v1.0.0`（稳定配置）、`v1.1.0-beta1`（YU10 + skiavkthreaded 验证）
- 过程文档：`docs/SHAREABILITY-FAULT-DIAGNOSIS.md`、`docs/BETA-SKIAVKTHREADED-PLAN.md`、
  `docs/RELEASE-1.1.0-beta1.md` 等
