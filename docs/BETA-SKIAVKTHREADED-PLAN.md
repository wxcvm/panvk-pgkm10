# 下个测试版计划：支持 `skiavkthreaded`（SF RenderEngine Vulkan）

v1.0.0 已解决：
- SurfaceFlinger **device lost**（`GPU_SHAREABILITY_FAULT`，补丁 034）；
- 微信 acquire 路径无界等待（补丁 030）。

目前 `skiavkthreaded` 仍不可用的**唯一已知阻塞**：压缩 YU10（10-bit 视频）的
**Vulkan 外部格式导入缺失**。解锁界面合成 1272×2772 / `format:54` /
`usage 0x400900` 的缓冲时，`vkGetAndroidHardwareBufferPropertiesANDROID`
返回 `VK_ERROR_INVALID_EXTERNAL_HANDLE`，Skia `GaneshBackendTexture` 失败后 abort。

## 现状证据

- 探针 `gpu-p010-import-probe`：线性 P010 全部成功；压缩 YU10（case2）仍失败；
- 崩溃方法栈：`SkiaRenderEngine::getOrCreateBackendTexture` →
  `GaneshBackendTexture` → `abort('Failed to create a valid texture ... format:54 usage:4196608')`；
- Mesa 上游（26.3/main）的 `vk_android.c` fourcc 映射只有 YVU420/NV12/P010/P210/XBGR8888，
  **没有 YU10**；PanVK 的 AFBC 支持目前仅 GL 侧（Panfrost）完成，Vulkan 侧未接线。

## 实施步骤（补丁 035+）

1. **`vk_android.c`**：`DRM_FORMAT_YU10`（fourcc `0x30315559`）映射到外部格式；
   与 AFBC modifier（`0x0800000000000041`/`0x72` 等）一起透传；属性查询直接给出
   `SAMPLED_IMAGE | MIDPOINT_CHROMA_SAMPLES`，不再走 `GetPhysicalDeviceFormatProperties2`
   的非法 VkFormat 查询。
2. **`panvk_android.c` / `panvk_image.c`**：接受外部格式 + 显式 modifier，
   建立单平面 10-bit 420 图像；复用 `pan_afbc`/`pan_layout` 的 AFBC YUV 布局
   （GL 侧 25.2 已实现，可参考其 tile/header/surface stride 计算公式）。
3. **采样**：`vk_format_get_ycbcr_info` 无法覆盖外部格式，需要在 PanVK 的
   YCbCr lowering 中为“外部格式 + YU10”补一条软件 CSC 路径（或映射为
   Panfrost 的 `Y10_UV10_420` 类格式）。
4. **验证顺序**：
   - 先跑 `gpu-p010-import-probe` case2，要求属性/图像/内存/视图全部 `VK_SUCCESS`；
   - 再跑一个只渲染 10-bit 纹理的独立测试（离屏），确认无 GPU fault；
   - 最后才在运行时把 `debug.renderengine.backend=skiavkthreaded` 应用到 SF，
     做锁屏/视频/通知栏压力；失败即回滚到 `skiagl`。
5. **风险控制**：SF RenderEngine Vulkan 是高风险配置（ColorOS 还会用
   layer caching / 10-bit 显示增强）；测试版默认仍 `skiagl`，`skiavkthreaded`
   作为显式 opt-in，并保留一键回滚与失败安全。

## 验收标准

- SF RenderEngine（Vulkan）启动后解锁/锁屏/通知栏压力 ≥5 分钟无 abort、无 device lost；
- 10-bit 视频层/锁屏合成不崩溃（颜色正确性可接受误差范围内）；
- 微信、相机、浏览器功能回归通过；
- 与 `skiagl` 配置相比性能无显著回退（允许小范围波动）。

## 备注

Beta 版本号计划 `1.1.0-beta1`；在正式发布前保持 `enable_global` 默认关闭、
`skiavkthreaded` 默认关闭。
