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

## 突破：GPU 非缓存导入消除 fault（2026-10-17 21:38）

| 实验 | 结果 |
|---|---|
| 033：正常 AFBC 导入 + 交互压力 | 8 秒内 fault（图像日志：fmt=37、1088×2432、modifier 0x…351 等） |
| 033：`afbc.linear_import=1`（强制 linear 处理） | 4 秒内 fault → **AFBC 被排除** |
| **C：`debug.panvk.kbase.import_set=0x200000`（GPU_UNCACHED）** | **60 秒交互压力 NO_FAULT** |
| **D：GPU_UNCACHED + `import_clear=0x40000`（去 SHARED）** | **60 秒 NO_FAULT** |

根因：kbase 把导入的 gralloc 缓冲映射为 **可缓存 CPU 内存**（内核 `out.flags`
含 `BASE_MEM_CACHED_CPU`）。当 GPU 以 cached 方式访问这些共享页时，GPU 事务的
共享性属性与页表共享性不一致，Mali MMU 报 `GPU_SHAREABILITY_FAULT`；kbase 将
context 标记 device-lost，HWUI/Skia 的 RenderThread abort → SystemUI 死亡/黑屏。

修复（补丁 034）：导入标志默认追加 `BASE_MEM_UNCACHED_GPU`（GPU 非缓存访问），
CPU 侧缓存一致性仍由显式 `KBASE_IOCTL_MEM_SYNC` 保证；保留
`debug.panvk.kbase.import_clear` 供 A/B（清 `0x200000` 可恢复 cached 行为）。

验证计划：034 构建完成后
1. 不设任何属性 + skiavk，锁屏/通知栏压力 ≥3 分钟应无 fault；
2. 微信/公众号回归（渲染、冷启动）；
3. 性能对比（导入缓冲变为 GPU 非缓存，需确认没有明显回退）；
4. 通过后把 034 纳入发布模块默认，skiavk 组合才可考虑启用。

## 修复验证（补丁 034，2026-10-17 22:00）

| 项目 | 结果 |
|---|---|
| 034 驱动（`e62177fb…`，16 个补丁） | 构建成功 |
| 运行时注入 + skiavk，无属性默认配置 | 184 秒锁屏/通知栏压力 **NO_FAULT** |
| 模块 system 作用域开机挂载 + skiavk（HWUI Vulkan） | 30 秒 boot_completed，props 正确（`skiagl` / `skiavk`） |
| 整机 200 秒锁屏/通知栏压力 | **faults=0，SystemUI 全程存活**（pid 不变） |
| SurfaceFlinger | `vulkan_maps=0`（GL 合成，符合设计） |
| SystemUI | `vulkan_maps=4`（HWUI Vulkan 生效） |
| 微信 | 公众号页正常渲染（截图核对），无 VK 错误 |
| 崩溃 | 无新增 tombstone；dropbox 仅无关的 Adaway 崩溃 |

模块更新：payload 换成 034 驱动（`GPU_SHA=e62177fb…`，version 0.4.0-wsi7），
`hwui_use_vulkan` 的 `debug.renderengine.backend` 保持 `skiagl`（只开 HWUI Vulkan）。

### 代价与边界

- 导入缓冲默认 **GPU 非缓存**，可能带来少量采样/合成性能损失（大小待测）；
  可用 `debug.panvk.kbase.import_clear=0x200000` 恢复 cached 行为做 A/B；
- SF RenderEngine 仍必须 `skiagl`：压缩 YU10 的 Vulkan 导入尚未实现（上游也没有）；
- 034 只解决 shareability fault，不等于系统 UI Vulkan 无任何其他风险，仍需长期观察。

## 性能与重复性（2026-10-17 22:17–22:22）

**性能 A/B（Settings HWUI Vulkan，各 5 轮双向滑动，`dumpsys gfxinfo`）**

| 配置 | 帧数 | Janky | p50 | p90 | p95 | p99 |
|---|---|---|---|---|---|---|
| 034 默认（导入 GPU-uncached） | 1517 | 33 (2.18%) | 13ms | 17ms | 20ms | 25ms |
| 恢复 cached（`import_clear=0x200000`） | 1528 | 40 (2.62%) | 13ms | 19ms | 21ms | 26ms |

非缓存导入**没有性能回退**（jank 与 p90 略优），因此可作为默认。
微信冷启动（当前配置）中位约 1.0s，与 OEM 基线（~0.9s）同量级。

**重启重复性**

| 项目 | 结果 |
|---|---|
| 重启后 boot_completed | 成功（约 30 秒） |
| 模块自动挂载 | `mounted wsi7 system-wide (attempt 1)` |
| props | `renderengine=skiagl`、`hwui.renderer=skiavk`、`acq.replay=true` |
| 驱动 | `e62177fb…`（034） |
| SF / SystemUI Vulkan 映射 | 0 / 4 |
| GPU fault | 0 |
| 重启后状态（5 分钟） | fault=0，SystemUI pid 不变，无新崩溃（压力脚本未完整落盘，以整机 200 秒压力结果为准） |

**结论**：当前配置可开机自动启用、可重复、性能无回退，已具备日常开启条件；
若出现问题，禁用 `MTK_D8100_Vulkan1.4.Panvk` 与 `hwui_use_vulkan` 后重启即可回滚。
