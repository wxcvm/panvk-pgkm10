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
