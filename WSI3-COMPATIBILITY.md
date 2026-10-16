# WSI3 全局兼容性复核（2026-10-16）

WSI3 的 AFBC 对齐修复通过了星穹铁道实屏开启、关闭、再次开启对照，
但全局启用后的微信 Flutter 页面出现 ANR，同一环境另有 SurfaceFlinger
纹理创建失败。当前结论是 **游戏显示问题得到修复，全局兼容性未通过**。
默认关闭策略保留；已开启的设备应关闭全局替换并完整重启。
修改 `driver.conf` 只影响后续启动，不会卸载当前挂载或替换进程中已加载的库。

本记录复核用户提供的分析报告及其原始 ANR、tombstone。
原始设备日志、用户报告、应用内容和 OEM 二进制不随仓库发布。

## 驱动身份与微信阻塞位置

四份 ANR 的 PanVK Build ID 均为
`cdc8d39f701ed5ee1486fa29db15c2e276498053`，匹配固定 WSI3 构建：

- 源提交 `9d9c0dc991d91c06e24a9ee811674d365a7d7fcc`；
- [Actions 38730614373](https://github.com/wxcvm/MoveCertificate/actions/runs/38730614373)；
- 库 SHA-256 `c24c37772f9494e8531fc8cbda9640a091859055fb63e563d44661b2308d69f1`。

主线程等待 Flutter surface 变更完成，光栅线程的栈重复出现
`vkQueueSubmit → vk_device_flush → vk_queue_flush → vk_queue_submit_final →
panvk_v10_gpu_queue_submit → vk_sync_wait → kbase_cpu_sync_wait_one →
pthread_cond_timedwait`。这是图形提交阻塞的直接证据；不能据此证明其他所有原因
均已排除，或证明对应 GPU 任务已经提交而只是没有完成。

按固定 Mesa 基线、上游补丁顺序和本仓库补丁重建实际源文件，再核对实际库的
AArch64 反汇编，得到以下位置，不能套用未打补丁的 Mesa 行号：

| ANR 库内地址 | 对应代码 | 能确定的含义 |
| --- | --- | --- |
| `0xf0cce0`，`panvk_v10_gpu_queue_submit+3120` | `panvk_queue_submit_ioctl_kbase` 输入等待循环中的 `vk_sync_wait(..., VK_SYNC_WAIT_COMPLETE, UINT64_MAX)` | 当前提交在等待输入同步对象；位于本次 GPU 工作发布之前 |
| `0xdab558`，`kbase_cpu_sync_wait_one+156` | `KBASE_CPU_SYNC_RESET` / `KBASE_CPU_SYNC_WAITING` 共用的条件变量等待 | 可能等待信号载荷建立，也可能等待另一个线程完成对该载荷的等待；仅靠栈不能区分 |

因此，报告指向的 DRM `force_sync` 调试分支和初始化等待并不是本次 ANR 的已定位
调用点。实际 Kbase 路径还包含默认开启的同队列 GPU 等待优化；能够识别为同队列
目标或已完成状态的对象不会经过上述 CPU 完成等待。这也意味着不能把所有 Android
acquire/release 都描述成阻塞 CPU 等待 GPU 完成。

## 不应直接采用的修复推论

- 动态依赖没有 `libdrm.so` 不代表库中没有 DRM 代码。本构建静态链接 libdrm；
  Kbase 后端选择需要结合实际源码、运行设备和调用地址判断。
- 020 只在 Kbase 上关闭不适用的 DRM 同步载荷复制回调，使 Android release
  使用公共 `QueueSubmit2` 回退路径；它不设置 `force_sync`。恢复旧回调会重新进入
  已实机复现 `ENOTTY` 的 DRM ioctl 路径。当前微信栈也不能单独证明 020 是根因。
- 实际 `kbase_cpu_sync_wait_one` 在载荷等待回调返回 `VK_TIMEOUT` 后将状态恢复为
  `PENDING` 并广播条件变量；成功时才释放对应 sync-file waiter。报告所说
  “超时永久留在 WAITING”与这份二进制的源码不符。超时后仍未完成的载荷不能
  直接释放，否则可能破坏后续合法等待。
- 删除等待、伪造成功或统一替换成短超时都不能修复丢失的同步依赖。
  需要识别具体对象的 RESET/WAITING 状态、信号来源及提交顺序，再做有界独立复现。

## SurfaceFlinger 是另一条待复现路径

两份 tombstone 记录 RenderEngine 在 `GaneshBackendTexture` 中主动中止，
错误为无法创建有效纹理。缓冲区尺寸 1272×2772、stride 1280、format 54、
usage 4196608，非保护内容、非写入用途。

54 即 `0x36`，对应 `YCBCR_P010`，是十位 YUV 视频格式，见
[AOSP PixelFormat 定义](https://android.googlesource.com/platform/hardware/interfaces/+/refs/heads/master/graphics/common/aidl/android/hardware/graphics/common/PixelFormat.aidl)。
这提供了 AHardwareBuffer 元数据、外部格式及多平面纹理导入的具体复现条件。
现有 tombstone 尚不能证明与微信信号量阻塞为同一个缺陷。

原厂重启后，独立程序直接加载 OEM HAL 和固定 WSI3 ICD，各自创建 1272×2772
缓冲区，实测 stride 均为 1280。未更改系统挂载、属性或运行中的应用。
每个诊断进程由外部 30 秒超时保护；两轮均正常退出，没有触发超时。

| AHB 格式 / usage | 原厂属性查询 | WSI3 属性查询 |
| --- | --- | --- |
| RGBA8888 / `0x100` | `VK_SUCCESS` | `VK_SUCCESS` |
| P010 / `0x100` | `VK_SUCCESS` | `VK_ERROR_INVALID_EXTERNAL_HANDLE` |
| P010 / `0x400900`，与 tombstone 相同 | `VK_SUCCESS` | `VK_ERROR_INVALID_EXTERNAL_HANDLE` |

失败发生在 `vkGetAndroidHardwareBufferPropertiesANDROID`。WSI3 日志依次报告
`unsupported native buffer format 0x36`、`Failed to get drm_fourcc` 和
`Failed to get u_gralloc_buffer_basic_info`。
实际补丁后的 `fallback_gralloc_get_buffer_info` 在旧格式转换失败时提前返回，
后面新增的 `panvk_v19_query_mapper` 因而没有机会读取此 P010 缓冲区的标准元数据。
这是已复现的属性查询缺陷及具体控制流问题，不能通过猜测平面偏移或伪装 RGBA 修复。

后续应验证现代 mapper 查询的顺序、P010 多平面元数据及颜色信息，再验证图像
导入、采样和真实合成。当前独立程序仅覆盖分配和属性查询，没有重现完整 Skia
调用链；修复该查询前置阻断也不代表余下导入、采样阶段一定正常。

## 后续验收要求

1. 完整重启回原厂，核对 Vulkan 和 ColorX 哈希及实际进程映射，并重试同一微信页面。
2. 在独立进程直接加载驱动，分别复现输入信号量生命周期和 P010 导入，外部超时
   约束诊断进程；无需重新全局启用 WSI3。
3. 只有具体缺陷修复和对应回归通过后，再验证微信、系统视频合成、浏览器和游戏。
   单应用的显示对照不作为全局稳定性结论。

完整重启后，已在 init、两个 Zygote 和 WebView Zygote 的独立挂载命名空间核对
原厂 Vulkan/ColorX 哈希；`enable_global=0`，硬件合成保持原设置，诊断属性为空。
用户重试此前卡死的微信公众号页面，确认恢复正常。这一回退对照支持 WSI3
全局启用与此次 ANR 的关联，但尚未定位造成错误等待的具体同步对象。
P010 属性查询已独立复现；微信同步复现与两条路径的修复仍待完成。
这里没有发布新的驱动二进制，也没有宣称 ANR 已修复。
