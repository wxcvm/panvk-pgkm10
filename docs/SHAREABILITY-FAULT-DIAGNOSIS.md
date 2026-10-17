# SystemUI `VK_ERROR_DEVICE_LOST` 诊断与修复（2026-10-17）

## 症状

开启 `hwui_use_vulkan` 模块（`debug.renderengine.backend=skiavkthreaded`、
`debug.hwui.renderer=skiavk`）并全局挂载 PanVK 后：

- 解锁/锁屏界面出现后不久（数秒到数分钟）整屏卡死、黑屏；
- 实际是 SystemUI 崩溃重启，不是输入触发（来不及输完密码只是时间不够）；
- 之前另一条崩溃是 SurfaceFlinger 在解锁界面 abort（压缩 YU10 纹理创建失败）。

## 证据

### SystemUI tombstone（20:16:08）

```
Process: com.android.systemui
Abort: 'VK_ERROR_DEVICE_LOST (RenderThread):
        No details: VK_EXT_device_fault not available/enabled.'
RenderThread:
  skgpu::InvokeDeviceLostCallback
  → onVkDeviceFault
  → deviceLostProcRenderThread
```

### 内核日志（pstore，同一次启动）

```
mali 13000000.mali: GPU Fault 0x22e00488 (GPU_SHAREABILITY_FAULT) in AS1 at 0x00000002435010ff
mali 13000000.mali: GPU Fault 0x22e00488 (GPU_SHAREABILITY_FAULT) in AS2 at 0x00000002435010ff
mali 13000000.mali: GPU Fault 0x00e00488 (GPU_SHAREABILITY_FAULT) in AS1 at 0x00000002435010ff
```

**GPU_SHAREABILITY_FAULT** = 同一批物理页在不同地址空间/映射上的共享性
（cache coherency）属性不一致，GPU 访问时 Mali MMU 报错；kbase 将 context 标记
device-lost，HWUI RenderThread 收到 `VK_ERROR_DEVICE_LOST` 后 abort。

### 根因

kbase 后端（`src/panfrost/lib/kmod/kbase_kmod.c`，`kbase_kmod_import_dmabuf()`）
对**所有** dma-buf 导入硬编码：

```c
BASE_MEM_IMPORT_SHARED | BASE_MEM_COHERENT_SYSTEM
```

`COHERENT_SYSTEM` 强制内核把导入区域标为 system-coherent，而 ColorOS 的
gralloc/HWC/OEM DDK 对同一批系统 buffer 的映射并非都使用该属性（系统 UI 与
SurfaceFlinger 共享的合成缓冲尤其如此），于是同一物理页在两个地址空间里
共享性不一致，触发上述 fault。

我们的后端本身 `is_io_coherent == false`，所有 GPU 访问前有显式
`KBASE_IOCTL_MEM_SYNC`，因此 `COHERENT_SYSTEM` 并非必需。

## 修复（补丁 031）

`patches/031-kbase-import-coherency.patch`：

1. 导入标志去掉无条件的 `BASE_MEM_COHERENT_SYSTEM`，保留共享显示所需的
   `BASE_MEM_IMPORT_SHARED`；
2. 新增 Android 属性覆盖（真机 A/B 不用重编）：
   - `debug.panvk.kbase.import_clear=<hex mask>`
   - `debug.panvk.kbase.import_set=<hex mask>`
   每个 dma-buf 导入时读取；
3. 保留原有环境变量覆盖（`PANVK_KBASE_IMPORT_CLEAR/SET`）。

构建方式：诊断工作流（`panvk-diagnostic.yml`）读取 `diagnostic-build.json`，
已把 031 加入补丁列表。

## 验证计划（构建完成后执行）

1. 新驱动先跑独立 P010 探针，确认导入链路未回归；
2. 运行时重新绑定到应用孵化命名空间（不重启）；
3. 单个应用开 HWUI Vulkan（`debug.hwui.renderer=skiavk`，不动 SystemUI）渲染数分钟，
   确认无 `GPU_SHAREABILITY_FAULT`；
4. 再验证 SystemUI/锁屏：重启 SystemUI 后多次锁屏/解锁与输入；
5. 观察 `/sys/fs/pstore`、`/data/system/dropbox`、`mesa` 日志。

## 边界

- 本修复针对 device-lost（共享性）；**SF RenderEngine 走 Vulkan 仍缺压缩 YU10
  外部格式导入**（Mesa 上游 Vulkan 侧也没有，PanVK 的 AFBC 仅 GL 侧支持），
  因此 `debug.renderengine.backend` 应保持 `skiagl`；
- skiavk 在 ColorOS 上仍属实验配置，修复后需重复锁屏/输入压力测试才能判定可用。

## 实机结果（2026-10-17 20:50，031 构建 bbc604cd…）

- 新驱动构建成功（BuildId `fe8415a8…`），P010 探针无回归（线性 P010 通过）；
- 单应用 HWUI Vulkan（Settings）连续 4 分钟无 GPU fault / 无 tombstone；
- 但 SystemUI（锁屏/通知栏）在 031 驱动下**仍然出现 GPU_SHAREABILITY_FAULT**
  （dmesg：`GPU Fault 0x20e00488/0x00e00488 (GPU_SHAREABILITY_FAULT) in AS1/AS2`），
  随后 SystemUI 卡死并触发 ANR：
  `Input dispatching timed out (NotificationShade is not responding, 5000ms)`；
- 结论：**去掉强制 `COHERENT_SYSTEM` 并不能消除该 fault**，故障不（只）是导入标志问题；
  需要进一步定位是哪个缓冲/操作（HWUI 的 AFBC/线性离屏缓冲、锁屏模糊、还是
  与 OEM DDK 共享的系统合成缓冲）触发共享性冲突。
- 当前处置：手机已回全部原厂（模块全禁用），锁屏/输入正常；skiavk 配置仍不建议开启。

### 下一步候选

1. 在驱动里给 import/映射加 per-buffer 日志（含 import flags、modifier、
   usage、stride），复现并对照 fault 地址定位具体缓冲；
2. 用 `debug.panvk.kbase.import_clear/set` 属性做 flag 组合 A/B（需要
   `mali_kbase_ioctl.h` 里 BASE_MEM_* 数值）；
3. 排查 HWUI Vulkan 的 AFBC 离屏/锁屏模糊路径（可试关闭 PanVK 的 AFBC 或
   `debug.hwui.renderer=skiavk` 下禁用 hardware bitmaps/blur 对照）；
4. 若短期无法根治：稳定方案 = skiavk 关闭 + PanVK 仅注入应用（微信公众号卡死已修复）。

## 实验记录（2026-10-17 20:20–21:20）

| 实验 | 结果 |
|---|---|
| 031：导入默认去掉 `COHERENT_SYSTEM` | 仍然 fault（SystemUI 数分钟内 ANR/死） |
| import flag A/B：`import_set=0x400`（旧默认） | 8 秒内 fault |
| import flag A/B：`import_clear=0x40000`（去掉 SHARED） | 4 秒内 fault |
| 032：`debug.mesa.movecert.afbc.disable=1` | 仍 fault（但显式 modifier 导入绕过该检查，实验无效） |
| 交互压力（锁屏/解锁/通知栏） | 稳定复现 fault（4–14 秒） |

现场捕获（`fault-capture.log`，18.9 MB）：

- fault 前 SystemUI（pid 19175）在 21:04:58 被 ActivityManager 记录
  `has died`（无 tombstone，属 device-lost 回调/被杀）；
- SystemUI 死前 1 秒大量 **AFBC RGB 图像导入**：fourcc `0x34324241`（"AB24"，
  32bpp 10-bit RGB）、modifier `0x0800000000000072`（115 次）与
  `0x0800000000000151`（14 次）、以及 linear 96 次；
- 这些导入来自 ColorOS 系统组件（如 `com.coloros.smartsidebar:edgepanel`），
  说明 skiavk 下多个系统 UI 进程都在用 PanVK 采样/合成系统缓冲；
- 导入 flags 均为 `0x4000f`（patch 031 默认），kernel 回 `outflags=0x4500f`
  （NEED_MMAP|CACHED_CPU|SHARED），即非 coherent。

当前结论：**fault 与导入标志无关；AFBC 是否相关尚未被有效验证**（显式导入
绕过 032 的开关）。下一步补丁 033：记录每个 AFBC 图像（format/extent/modifier/
usage），并允许通过 `debug.mesa.movecert.afbc.linear_import=1` 把导入的 AFBC
图像按 LINEAR 处理（像素错误但可验证 fault 是否来自 AFBC 解码/布局）。


