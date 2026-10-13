# PGKM10 / Android 17 的 RC3 导入检查

2026-10-12 使用手机已有的 Termux clang 21 构建独立探针，在 root 诊断进程中直接
加载固定的官方 RC3。没有替换系统驱动、改变系统属性或重启游戏。下面是初始化与
小型缓冲区导入结果，不是游戏、渲染正确性或 Vulkan 一致性认证结果。

| 检查 | 结果 |
| --- | --- |
| 原厂系统 Vulkan 接口 | Mali-G610 MC6，API 1.1.177；设备创建及 AHB 属性查询成功 |
| RC3 独立 ICD | Mali-G610 MC6，API 1.4.363；实例及设备创建成功 |
| RC3 私有 native-buffer 扩展 | specVersion 8；usage/usage2、acquire 和 release 入口存在 |
| RC3 系统 native-buffer 图像创建 | RGBA UNORM 和 sRGB 均返回 `VK_ERROR_INVALID_EXTERNAL_HANDLE` |
| 同一缓冲区的 AHB 外部内存路径 | 图像创建、真实 GPU 内存导入、绑定均返回 `VK_SUCCESS` |

本机 vendor API / VNDK 为 31，mapper 是 MediaTek HIDL gralloc4。独立探针的 Mesa
日志确认 mapper 加载和完整布局解码成功，所以不能简单归因于 gralloc4 不受支持。

## 可复现的 FD 选择错误

探针自己的 64×64 RGBA 缓冲区包含三个 FD：

| 索引 | 类型 | 可查询大小 | RC3 的 FD 属性查询 |
| --- | --- | --- | --- |
| 0 | `gralloc_extra` 控制句柄 | 不可 seek | `VK_ERROR_INVALID_EXTERNAL_HANDLE` |
| 1 | 真正的 DMA-BUF | 16384 字节 | `VK_SUCCESS` |
| 2 | ashmem 元数据 | 2404 字节 | 也返回成功，因此仅查询 FD 属性不够 |

Mesa `vk_android_import_anb_memory` 仍将 `anb->handle->data[0]` 作为 DMA-BUF。
日志明确停在 `GetMemoryFdPropertiesKHR failed`，与第 0 个 FD 的查询结果一致。
上游 [android/008 补丁](https://github.com/zenithblue-oss/panvk-kbase-android/blob/fd6ed91eff1c8d3a83307a2348b959bb93797011/patches/android/008-ahb-dma-buf-finder.patch)
修正了 AHB 的 FD 搜索，但未修改这条系统 native-buffer 内存导入路径。

这为 ColorX 绕过之后交换链为空提供了具体解释；游戏的实际 `CreateSwapchainKHR`
返回码尚未单独捕获，不能把独立探针当作游戏全流程验证。Quetta 花屏也仍未定位。

## 源码修复候选

`patches/019-anb-import-fd-discovery.patch` 基于固定 Mesa 提交
`5a07217f034b3e50d8c7c7794f97a2df1742613b`，应在 RC3 上游补丁之后应用。
它遍历 FD，过滤控制/元数据设备，检查可 seek 的大小、兼容内存类型，并验证真实
GPU 内存导入。失败时保留调用方的原 FD，关闭自己复制的 FD；不假定真实 FD 是第 1 个。
代码沿用 Mesa 的 MIT 许可，许可文本见 `licenses/Mesa`。

从该源码补丁提取同一个 helper，使用探针实际验证过的 LINEAR 布局测试：

- 原句柄中 DMA-BUF 位于索引 1：真实 GPU 内存导入及图像绑定成功。
- 只提供 gralloc_extra 和 ashmem 元数据：拒绝，返回 `VK_ERROR_INVALID_EXTERNAL_HANDLE`。
- 将真实 DMA-BUF 放到索引 2：仍成功导入并绑定，证明未硬编码索引。

helper 用 Android clang 的 `-std=c11 -O2 -Wall -Wextra -Werror` 编译通过；补丁对
固定 Mesa 源码通过 `git apply --check`，在该文件应用 RC3 的 android/008 和
android/014 后也通过应用检查。后续完整驱动重建结果见下文。
当前安装包继续保留官方 RC3 原始字节，源码补丁未应用到其中的 `.so`，已知失败平台
的全局替换限制保持不变。也仍需解决 ColorX 的独立空函数调用冲突。

## RC3-anbfix1 完整构建与实机验证

2026-10-13 的 [Actions 构建](https://github.com/wxcvm/MoveCertificate/actions/runs/38321428152)
已将固定 RC3 的 172 个上游补丁及本项目的 019 补丁应用到 Mesa 并完成 Android arm64
构建。产物是独立实验 ICD，不是可安装模块；原有 wrapper2 中的官方 RC3 未替换。

- 源提交：`47f3007c322318c3ced60dc4df6b3f70329e85db`。
- 驱动 SHA-256：`f8727d6706322dd1e6e5839dda5a916f65b67aedfea605db0efe362e05df114c`。
- BuildID：`94768c47c0aba8ae70e46547616ea003c074cbef`；最低 Android API 35。
- 驱动标识：`PanVK-kbase RC3-anbfix1`，Vulkan API 1.4.363。

独立 root 进程直接加载这个完整驱动，自行分配 64×64 RGBA 缓冲区，得到以下结果：

| 检查 | 结果 |
| --- | --- |
| native-buffer RGBA UNORM / sRGB 图像创建 | 均成功；原始 RC3 对照均失败 |
| native-buffer UNORM 的 GPU 清屏、等待、CPU 回读 | 全部 4096 像素为预期 RGBA `(51,102,153,255)` |
| AHB 外部内存路径的相同清屏与回读 | 全部 4096 像素正确 |
| 64 次 native-buffer 导入、销毁 | 进程 FD 数量 22 → 22 |
| 元数据 FD 拒绝、真实 DMA-BUF 改到索引 2 | 均符合预期 |

这些检查验证了内存导入及小图像操作，未覆盖 sRGB 像素值、显示交换链、游戏渲染或
长时间稳定性。它们不构成 Vulkan 一致性认证。

游戏临时测试同时保留系统 Vulkan 接口并精确绕过 ColorX 的 Vulkan 注入。首次用户
反馈能进入且画面正常，但游戏实际报告 `OpenGLES3`，当时未保持加载 PanVK，故不能
记为新版 Vulkan 游戏测试通过。将临时驱动的标签从 `vendor_file` 调整为
`same_process_hal_file` 并重启后，进程映射确认加载修复版 PanVK，系统日志报告
`QueueSignalReleaseImageANDROID failed: -13`，用户反馈卡住或黑屏。标签变化与实际
加载的变化同时出现，但没有捕获到明确的 AVC 拒绝，不能单凭此确定此前的回退原因。
本轮测试已恢复原厂 HAL 和增强库，开机配置仍为 `enable_global=0`。

## 第二个错误：kbase 错用 DRM 同步复制

针对上述提交错误，独立探针在同一设备上复现：

| 路径 | RC3-anbfix1 结果 |
| --- | --- |
| 信号量提交 → `GetSemaphoreFdKHR` → `poll` | 成功，导出的同步 FD 可正常完成 |
| 信号量提交 → `QueueSignalReleaseImageANDROID` | `VK_ERROR_UNKNOWN`（-13） |
| 第二条路径的 Vulkan 调试消息 | `DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD failed: Inappropriate ioctl for device` |

固定 Mesa 的 `panvk_vX_device.c` 无条件设置
`copy_sync_payloads = vk_drm_syncobj_copy_payloads`。RC3 的 kbase 改动没有取消这个
DRM 专用回调。Android 公共运行时发现该回调存在便复制同步载荷，而 kbase 使用的
同步对象及 `/dev/mali0` 不支持 DRM syncobj ioctl。

`patches/020-kbase-disable-drm-sync-payload-copy.patch` 仅在 kbase 后端保留空回调，
使公共运行时走已有的 `QueueSubmit2` 路径，并使用 kbase 自己的同步 FD 导出。
DRM 后端仍保留原有回调。RC3-anbfix2 包含 019 和 020，已在
[Actions](https://github.com/wxcvm/MoveCertificate/actions/runs/38346477496) 完整构建。
SHA-256 为 `621235874d9b00f4f9deb7a37c0a10df1ba71ef19839bfed9e3bb290eea31fa2`，
BuildID 为 `2baa743c12ed70b959193ef456634835352d8bfe`。实机独立探针确认：

- 64 次 `QueueSignalReleaseImageANDROID` 均成功，返回的同步 FD 都能完成；-13 错误消失。
- 空等待列表成功返回 FD -1；普通同步 FD 导出也通过。
- native-buffer 与 AHB 的 GPU 清屏回读仍全部正确。
- 只导出和关闭同步 FD 时，测试前后 FD 数量均为 23。

## 第三个错误：导入同步 FD 后丢失释放入口

在上述测试中加入 `AcquireImageANDROID`，将导出的同步 FD 导入另一个信号量，
再提交等待并销毁信号量。虽然 64 次操作都成功，结束后进程却比仅导出对照多出
64 个 FD。这与图像导入销毁测试的 FD 数量稳定是不同路径。

RC3 的 `kbase_cpu_sync_import_sync_file` 复制 FD 并分配一个 waiter；等待完成后，
`kbase_cpu_sync_wait_one` 直接将 `pending_data` 和 `pending_wait` 设为空，未调用
已有的 `kbase_sync_file_waiter_free`。后续销毁失去了找到并释放这个 FD 的入口。
reset、signal、重新设置载荷和移动到已有目标也有丢弃旧 waiter 的路径。

`patches/021-kbase-sync-file-waiter-lifetime.patch` 在丢弃旧载荷前释放它拥有的 waiter。
移动时只释放目标的旧载荷，保留来源转移的所有权；超时保持 waiter 以便继续等待。
RC3-anbfix3 包含 019、020、021，已完成
[完整构建](https://github.com/wxcvm/MoveCertificate/actions/runs/38381304473) 和独立实机回归。
anbfix2 未进行全局游戏测试。不能把同步接口返回成功等同于长时间游戏稳定。

第三版产物 SHA-256 为
`4f91569f9be0bb3a148ac1ee7c03dbfc77e8b5e36fa5d2a97a8c16b696b39345`，BuildID 为
`d31436d9d931afeede91c787f1d9fb43e926b281`，源提交为
`a540dc3648f45751b8c88af478e66228c54f1762`。实机结果：

| 检查 | RC3-anbfix3 结果 |
| --- | --- |
| 64 次释放图像 → 导出同步 FD → poll → AcquireImageANDROID → 提交等待 | 全部成功 |
| 上述循环前后 FD 数量 | 23 → 23，无增长 |
| 空等待列表与普通同步 FD 导出 | 通过 |
| native-buffer UNORM / sRGB 图像创建 | 通过 |
| native-buffer 与 AHB 的 64×64 GPU 清屏回读 | 两条路径各 4096 像素全部符合预期 |
| 64 次 native-buffer 导入销毁 | FD 数量 22 → 22 |

测试进程使用独立缓冲区，没有修改系统挂载。

第三版随后进行了可回退的全局游戏测试，仍配合精确 ColorX Vulkan 绕过。游戏进程
映射确认上述 SHA 的驱动，游戏自身也报告 `graphicsDeviceType=Vulkan`。用户确认
可以进入且有画面，但反馈闪烁、重影或画面错位。约两分钟观察内未见此前的 -13
提交错误或新增 tombstone，FD 数量从 769 到 767；这些观察不能证明长时间稳定。
截图和短视频仅保存在本地诊断目录，不提交到仓库。

因此第三版修复了已复现的导入、提交和句柄泄漏问题，游戏渲染正确性仍未通过，
浏览器花屏也尚未验证。安装包的全局限制和默认原厂配置保持不变。

继续进行了两个独立可回退的诊断对照：`PANVK_DEBUG=sync` 强制等待 GPU 提交完成，
以及撤销 sync 后单独使用 `PANVK_DEBUG=no_crc` 禁用渲染目标 CRC 优化。通过 Mesa
支持的 `debug.mesa.panvk.debug` 临时属性设置；每轮均确认游戏仍报告 Vulkan。
用户对两轮均反馈没有改善或更严重，所以不能用这两个开关作为修复，也不能据此
确定具体的渲染错误来源。测试后已恢复原属性、原厂 Vulkan HAL 与增强库，并核对
init、Zygote 和 WebView 挂载命名空间，开机配置继续为 `enable_global=0`。
恢复后用户确认同一位置原厂画面正常、异常消失。该对照支持异常与 PanVK 测试配置
有关，但尚不能区分驱动渲染、OEM 集成和特定游戏工作负载中的具体原因。

## 继续缩小渲染异常范围

在保持系统原厂驱动的情况下，独立进程直接加载同一 SHA 的 anbfix3，完成以下
离屏回归。上游探针来源仍固定到 `fd6ed91eff1c8d3a83307a2348b959bb93797011`。

| 检查 | 实机结果 |
| --- | --- |
| 基础三角形、混合 | 通过；混合含 independent blend、dual source、logic op |
| 深度/模板、纹理采样、着色器运算 | 各 10、10、8 项通过；不支持的 D16S8 跳过 |
| 无附件多重采样与二级命令缓冲区切换 | 13 项通过 |
| draw parameters、descriptor model、occlusion query | 各 7、6、9 项通过 |
| 动态渲染、自定义边界颜色、depth clip control | 3 项通过 |
| 连续提交 | 5,000 次提交，每次 4 个渲染通道，探针像素检查通过 |
| GPU-only AHB 三角形渲染 | AHB 和 native-buffer 路径各在 64×64、2412×1080 通过 |

最后一项禁止 CPU usage，使分配条件更接近显示缓冲区；两条导入路径都渲染红色
三角形和蓝色背景，再通过 GPU 复制到独立的 coherent 缓冲区进行像素校验。
64×64 各检查 3,928 像素，2412×1080 各检查 2,599,722 像素（分配 stride 为 2,432），
均为零异常；三角形边缘留出栅格覆盖容差。该测试未让 SurfaceFlinger 显示图像，
因此不能据此排除显示交接问题。

另新增 `probe/` 的独立显示诊断 APK 与构建工作流，用同一驱动分别检查直接加载
和系统 Vulkan loader 路径。实际结果在运行后记录，不能将 APK 构建成功计为测试通过。
