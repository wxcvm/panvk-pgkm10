# 花屏根因确认：MTK HWC 叠加显示 PanVK 图层缓冲（2026-10-21）

## 现象

- 模块全局启用（`enable_global=1`、`scope=system`，驱动 `5eb3899d…`）后，
  **微信「公众号」Flutter 页面出现整屏大面积花屏**。
- 花屏出现时，**`screencap` 截图与 `screenrecord` 录屏完全正常**（多次验证：
  12 帧连拍、75 秒录屏 746 帧全部干净）。
- 微信层级的合成方式为 `DEVICE`（HWC 直接叠加合成），位于
  `BizFlutterTLFlutterViewActivity` 的 BLAST `SurfaceView` 上。
- 驱动内置实验开关结果：
  - `debug.mesa.movecert.afbc.disable=1`（禁用新建图像 AFBC）：花屏仍在；
  - `debug.mesa.movecert.afbc.linear_import=1`（强制导入图走线性）：渲染黑屏，
    说明交换链缓冲与 AFBC/修饰符相关，且强制线性会破坏渲染；
  - 两个属性可随时清零恢复，不影响正常配置。

## 决定性证据（用户实测）

**开发者选项 → 停用硬件叠加层（强制 GPU 合成）打开后，花屏消失、页面正常。**

→ 根因：**MediaTek HWC（显示硬件叠加/合成器）直接叠加显示 PanVK WSI
产出的图层缓冲时读错，花屏只出现在面板输出**；同一块缓冲由 GPU 合成
（截图/录屏/SF 客户端合成）读取完全正确。

结合 `panvk_wsi.c` 实现可知，当前 WSI 不是标准 Vulkan Android 交换链，而是：

```
自建 AHB(R8G8B8A8 + GPU_COLOR_OUTPUT|GPU_SAMPLED_IMAGE|CPU_READ)
  → panvk 渲染
  → present 时 ANativeWindow_lock() + CPU memcpy 到 SurfaceView 窗口缓冲
  → ANativeWindow_unlockAndPost()
```

内容本身正确（GPU 合成验证），问题在交给 HWC 叠加显示的缓冲/元数据不兼容。

## 临时可用配置

- 开发者选项「停用硬件叠加层」= 开。代价：所有帧走 GPU 合成，功耗/性能有损失；
  需确认重启后是否保持（部分 ROM 会重置）。
- 若要开机持久化：模块脚本在 `post-fs-data`/`service` 阶段设置对应的
  SurfaceFlinger 调试属性（待重连设备后确认该开关对应的 prop/setting 键名）。

## 修复方向

1. **阶段 2（根治方向）**：把 WSI 改成标准 Android Vulkan 交换链——
   `ANativeWindow_dequeueBuffer()` → 将 AHB 导入为 VkImage → GPU 直接渲染 →
   `queueBuffer` 带 fence。与 OEM 驱动同架构，HWC 叠加显示标准缓冲正常，
   同时去掉每帧 CPU memcpy。
2. **备选（绕过）**：驱动改为标准 KernelSU 模块挂载（`system/vendor`、
   `system_ext` 文件），KSU 默认对非 root 应用「卸载模块」→ 微信回 OEM 驱动；
   其他 App 关掉卸载即可继续用 PanVK。治标不治本，但当天可用。
3. **回滚**：KSU 禁用 `MTK_D8100_Vulkan1.4.Panvk` + 重启回 OEM。

## 复现/验证方法

- 微信打开「公众号」页面并滚动/进出文章；
- 花屏时截图/录屏应为正常（关键判据）；
- 打开「停用硬件叠加层」后应恢复正常；
- 驱动哈希验证：`sha256sum /vendor/lib64/hw/mt6895/vulkan.mali.so`
  应为 `5eb3899da6f16a7f6b7e80aab1a693da032831d4db1c99817fbcc1f160a3d4a6`。
