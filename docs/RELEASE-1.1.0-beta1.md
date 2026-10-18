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
