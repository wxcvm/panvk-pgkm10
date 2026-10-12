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
android/014 后也通过应用检查。完整驱动重建和集成运行测试尚未完成。
当前安装包继续保留官方 RC3 原始字节，源码补丁未应用到其中的 `.so`，已知失败平台
的全局替换限制保持不变。也仍需解决 ColorX 的独立空函数调用冲突。
