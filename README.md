# PanVK 启动脚本修复

这是现有 `MTK_D8100_Vulkan1.4.Panvk` 模块的替换安装包，模块 ID 保持一致。
默认 `enable_global=0`：安装后重启使用原厂 Vulkan HAL，可用于验证 Quetta 黑屏是否来自 PanVK。
安装器仅保留手机上原模块的 `vulkan.mali.so`，本仓库不包含或重新发布驱动二进制。

原脚本将同一个 arm64 ELF 挂载到 64 位和 32 位 HAL 路径；卸载脚本还尝试将不存在的
`old_mali.so` 写入 vendor 分区。修复后的脚本不写 vendor、不设置全局 RenderEngine 属性，
手动启用时只接受 AArch64 共享库，设置原厂 SELinux 标签并验证 64 位挂载结果。

手机现场日志显示 Quetta 已拿到 HTTP 200 和页面正文，但 Vulkan/Skia 初始化失败并黑屏。
这使 Vulkan 驱动成为明确的排查方向，尚不能证明关闭 PanVK 后已修复黑屏，需要重启验证。
没有当前二进制对应的源码和可复现构建信息，因此本改动只修复模块脚本并提供回退方案，
不声称修复 Mesa/PanVK 内部的渲染缺陷。

如需后续手动测试，可将模块目录的 `driver.conf` 中 `enable_global=0` 改为 `1` 后重启。
这会影响所有 64 位 Vulkan 应用；32 位 HAL 始终保留原厂版本。
