# PanVK WSI7 v1.1.0-beta1 — 测试版

下载：https://github.com/wxcvm/panvk-pgkm10/releases/tag/v1.1.0-beta1

> 测试版：在 `1.0.0` 基础上加入 **AFBC YU10（10-bit 视频/锁屏层）的 Vulkan 导入**
> 实验能力，为 `skiavkthreaded` 做前置准备。日常使用仍建议 `1.0.0`（SF RenderEngine
> 保持 `skiagl`、驱动 `e62177fb…`）。

## 新增内容

| 补丁 | 内容 | 状态 |
|---|---|---|
| 035 | 属性查询接受 `DRM_FORMAT_YUV420_10BIT`（不透明外部格式 `0x7f000001`） | ✅ 探针验证 |
| 036 | PanVK 外部格式映射、平面数/尺寸/视图处理 | ✅ 探针验证 |
| 037 | AHB 布局/内存/失败诊断日志 | 诊断 |
| 038 | AFBC 打包格式修正（`PIPE_FORMAT_R10G10B10_420_UNORM_PACKED`，`PAN_AFBC_MODE_YUV420_6C10`） | ✅ 探针验证 |

探针 `gpu-p010-import-probe` 对 SF 崩溃同款缓冲（format 54 / usage 0x400900 /
1272×2772 / AFBC 修饰符 `0x800000000000041`）全链路通过：

```
properties=0  CreateImage=0  AllocateMemory=0  BindImageMemory=0
Conversion=0  CreateImageView=0  → failures=0
```

## `skiavkthreaded` 状态（重要）

- **默认仍为 `skiagl`**（模块 props 与 `hwui_use_vulkan` 预设均保持 GL 合成）；
- 本次未完成 `skiavkthreaded` 的运行时闭环验证：
  - 运行时切换并重启 SurfaceFlinger 的试验导致框架重启，SF 未实际启用 Vulkan
    RenderEngine（0 个 Vulkan 映射），实验结论不足；
  - 需要下一步：确认 SF 在启动时读取该属性的方式，或构建一个采样读回测试
    （YCbCr conversion + shader CSC）先验证 10-bit 采样正确性，再开 SF Vulkan。
- 因此 `skiavkthreaded` 仍是**实验 opt-in**，不作为本测试版的默认能力。

## 包信息

- 驱动：`302232ed0407b8f173c73d4e5dd55461b9b9bbba1e02f7d0a98acd6c09d12d3a`（26,645,xxx B，019–038）
- 模块：`1.1.0-beta1`，versionCode 11
- ZIP：`PanVK-WSI7-PGKM10-v1.1.0-beta1.zip`
  sha256 `52985cd24c82235bb9fb0bb91996502af29b90026aacfe7e37a85bb861eabd2d`
- 安装/回滚方式与 1.0.0 相同；测试版请保留 `1.0.0` 包用于回退。

## 已知边界

- YU10 采样/合成正确性未验证（探针只覆盖属性/图像/内存/视图/转换创建）；
- `skiavkthreaded` 未闭环，SF RenderEngine 崩溃风险仍在；
- 游戏与 10-bit HDR 视频播放未覆盖。

## 运行时 SF 测试结果（2026-10-18 00:19，失败且实验无效）

- 尝试：hwui 预设 `debug.renderengine.backend=skiavkthreaded` +
  `debug.renderengine.vulkan=true` 开机，让 SurfaceFlinger 使用 Vulkan RenderEngine；
- 结果：SurfaceFlinger 仍在锁屏合成时 abort：
  `Failed to create a valid texture [1272,2772] format:54 stride:1280 usage:4196608`
  （tombstone_08），设备随后重启循环；
- **重要**：该次实验时系统级挂载的是 `1.0.0` 的 034 驱动（不含 035–038），
  因此 abort 属于已知的 YU10 导入缺失，**不能据此判断 038 的 YU10 导入是否足够**；
- 结论：`skiavkthreaded` 的运行时闭环仍需用 **038 系统级挂载 + 受控测试环境**重做；
  在手机日常环境反复尝试会导致 SF 崩溃循环，不建议在主力机直接开。

安全恢复：已把 `hwui_use_vulkan` 禁用、`renderengine.backend` 固定 `skiagl`、
驱动模块恢复 034 稳定 payload；设备正常。

## 运行时闭环验证成功（2026-10-18 09:43-09:50，一次实验启动）

配置：038 驱动系统级挂载 + `debug.renderengine.backend=skiavkthreaded`
+ `debug.renderengine.vulkan=true` + `debug.hwui.renderer=skiavk`（HWUI Vulkan）。

| 验证项 | 结果 |
|---|---|
| SurfaceFlinger RenderEngine | **`RE Vulkan (Ganesh)`，`Vulkan device initialized: 1`** |
| SF Vulkan 映射 | 4 个 `vulkan.mali` 映射（wsi7 已加载） |
| HWUI Vulkan（真实生效，不只是属性） | SystemUI/launcher/Settings 各 4 个 Vulkan 映射；`dumpsys gfxinfo` → `Pipeline=Skia (Vulkan)`；logcat `SkiaVulkanPipeline` |
| **SF 导入 YU10 十位层** | 成功：`ahb layout mod=0x800000000000041 fmt=0x7f000001 extent=1272x2772`（6 次锁屏合成） |
| GPU fault / abort | **0 / 0**（此前 `Failed to create a valid texture` 未再出现） |
| 稳定性 | 200+ 秒锁屏/解锁/通知栏交互，SF/SystemUI pid 不变，无 tombstone |
| 视觉正确性 | 截图核对：系统 UI 与文件管理器界面颜色/文字正常，无花屏黑屏 |

**结论**：`skiavkthreaded`（SF RenderEngine Vulkan）+ HWUI Vulkan + YU10 导入
在本机（PGKM10 / Android 17 / MTK MT6895）已验证可用。

### 如何启用（实验，默认仍关闭）

1. 驱动模块用 038 payload（beta1 ZIP 即是），`enable_global=1`、`scope=system`；
2. `hwui_use_vulkan` 模块：启用，并把 `system.prop` 改为
   `debug.renderengine.backend=skiavkthreaded`、`debug.renderengine.vulkan=true`、
   `debug.hwui.renderer=skiavk`；
3. 重启；验证 `dumpsys SurfaceFlinger | grep "RE Vulkan"` 与
   `dumpsys gfxinfo com.android.systemui | grep Pipeline`。

### 风险

- SF Vulkan 在 ColorOS 上仍属实验配置（曾出现 abort/黑屏历史）；建议先备份、
  保留一键回滚（禁用 hwui 模块 + 驱动模块后重启）；
- 长时间/游戏/10-bit HDR 视频播放仍未验证，建议观察后续稳定性。

## 永久启用（2026-10-18 已在本机生效）

本机已永久启用该配置（038 驱动 + `skiavkthreaded` + `vulkan=true` +
`hwui.renderer=skiavk`），并加载运行时看门狗：SF 10 分钟内重启 ≥3 次会自动回退
`skiagl`、禁用 hwui 模块并重启。重启后验证：SF `RE Vulkan (Ganesh)`、
`Vulkan device initialized: 1`、HWUI `Pipeline=Skia (Vulkan)`、GPU fault 0。
回滚：禁用 hwui 模块后重启。

## 修复：设置「画质超清增强 / 视频色彩增强」闪退（2026-10-18 10:20）

**现象**：进入 设置 → 显示与亮度 → 画质超清增强 / 视频色彩增强，约 1 秒后
`com.android.settings` 闪退；Twitter 等含 10-bit 视频的应用也会崩溃。
旧驱动 + 全局 Vulkan 时同样页面则是**花屏**而不是崩溃。

**根因**：崩溃发生在 app 的 HWUI `RenderThread`，abort 信息：

```
frameworks/base/libs/hwui/AutoBackendTextureRelease.cpp
Invalid GrBackendFormat. GrBackendApi==1, AHardwareBuffer_Format==4096.
```

即 **HWUI 的 Vulkan（Skia Vulkan/Ganesh）后端**在把 ColorOS 的厂商私有 /
10-bit YUV AHB（format 4096）包装成 Skia texture 时，拿不到有效
`GrBackendFormat`，直接 `LOG_ALWAYS_FATAL`。这是 Skia/HWUI Vulkan 路径对这些
AHB 格式的限制，与 PanVK 驱动的 10-bit 导入能力无关（探针与 SF 均正常）；
OEM 驱动下同一路径表现为花屏。

**修复**：HWUI 固定使用 GL（`debug.hwui.renderer=skiagl`、
`ro.hwui.use_vulkan=false`），**SurfaceFlinger 仍保持 Vulkan**
（`debug.renderengine.backend=skiavkthreaded` + `debug.renderengine.vulkan=true`）。

**验证（重启后）**：

| 项 | 结果 |
|---|---|
| SF RenderEngine | `RE Vulkan (Ganesh)`、`Vulkan device initialized: 1`、4 个 Vulkan 映射 |
| HWUI | `Pipeline=Skia (OpenGL)`、SystemUI 无 Vulkan 映射（GL 生效） |
| 两个增强页面 | 均可进入，Settings pid 不变、无 abort（此前闪退） |
| 花屏 | 不再出现（页面图像/文字正常） |
| GPU fault | 0 |

结论：**skiavkthreaded / SF Vulkan 保留可用；HWUI Vulkan 在本 ROM 上有该 AHB
兼容性缺陷，暂不启用。** 一键回滚：把 `debug.renderengine.backend` 改回
`skiagl` 后重启。
