# PanVK RC3 与原厂回退包

两个包使用相同模块 ID `MTK_D8100_Vulkan1.4.Panvk`，用于替换手机现有的旧 PanVK 模块。
安装任意一个都需要完整重启。只 bind 挂载 64 位 Vulkan HAL，不写 vendor 分区；
OpenGL/EGL 及 32 位 Vulkan 保留原厂。

- `PanVK-RC3-D8100-Vulkan.zip`：包含官方 RC3 Android arm64 二进制，默认启用新驱动。
- `PanVK-guarded-launcher-v1.0.1.zip`：不包含新二进制，默认关闭替换，重启回到原厂 HAL。

RC3 来自 [上游发布](https://github.com/zenithblue-oss/panvk-kbase-android/releases/tag/panvk-kbase-v0.1.0-rc3)。
上游记录了 Mali-G610 MC3 的测试；PGKM10 的 G610 MC6 / Android 17 全局 Vulkan HAL
尚未实测，不能将上游测试结果视为本机或 Quetta 的兼容保证。
官方 Android 构建关闭了 OpenGL/EGL/GLES，所以本包仅更新 Vulkan。

Actions 从固定发布下载，核对 ZIP 和库的 SHA-256、BuildID、AArch64 ABI、API 35、HMI
及三个 ICD 导出和系统动态依赖；保留二进制原始字节，不修改驱动声明或伪装扩展支持。
源提交、校验值见 `upstream.json`；上游原始构建记录保留在新包 `upstream/`，本包自己的
`VALIDATION.json` 明确记载本机运行验证尚未完成。构建时的 GPL/系统调用例外、MIT、Mesa
许可证声明随包保留；`licenses/Mesa` 来自固定 Mesa 提交，官方源码来源见上游 SOURCE.json。

原旧模块将同一 arm64 库挂到 32 位目录，并在卸载时尝试写回不存在的 old_mali.so；
这两项已移除。新库在安装及启动时检查校验值和最低 SDK，错误时保留原厂 HAL。
此前 Quetta 已收到 HTTP 200 和正文却出现 Vulkan/Skia 初始化失败，RC3 能否修复此问题
需要安装后的实机对照。

如需从新驱动回退，可在 Root 管理器禁用此模块并重启，或安装上述原厂回退包再重启。
也可将模块目录 `driver.conf` 中的 `enable_global=1` 改为 `0` 后重启。

本地打包新驱动：`python3 scripts/prepare-driver.py`（或 `--archive 官方adpkg.zip`），
然后运行 `python3 scripts/package.py`。驱动二进制只出现在忽略的 `driver-dist/` 和产物
ZIP 中，不进入源码 Git 历史。
