# PanVK RC3 与原厂回退包

两个包使用相同模块 ID `MTK_D8100_Vulkan1.4.Panvk`，用于替换手机现有的旧 PanVK 模块。
安装任意一个都需要完整重启。不写 vendor 分区；两个包都默认使用原厂 Vulkan、OpenGL/EGL。

- `PanVK-RC3-D8100-Vulkan.zip`：wrapper2 包含官方 RC3 Android arm64 二进制，默认关闭全局替换；库可供支持自选驱动的应用单独测试。
- `PanVK-guarded-launcher-v1.0.2.zip`：不包含新二进制，默认关闭替换，重启回到原厂 HAL。

RC3 来自 [上游发布](https://github.com/zenithblue-oss/panvk-kbase-android/releases/tag/panvk-kbase-v0.1.0-rc3)。
上游记录了 Mali-G610 MC3 的测试；2026-10-12 已在 PGKM10 的 G610 MC6 / Android 17
进行全局 Vulkan HAL 对照。星穹铁道两次在 ColorX 的
`colorx::vk::core::CxPhysicalDevice::constructFragmentShadingRatesInfo` 内调用空指针，
崩溃映射确认 RC3 BuildID。解除 RC3 挂载后用户确认能进入游戏。
因此启动器明确拒绝在 `ro.product.model=PGKM10` 且 SDK 37 时全局替换。
Quetta 部分花屏尚未单独定位。这是恢复原厂的兼容处理，未修复 PanVK 内部实现，
也未修改、禁用 ColorX 系统应用或伪装 Vulkan 扩展支持。
官方 Android 构建关闭了 OpenGL/EGL/GLES，所以本包仅更新 Vulkan。

Actions 从固定发布下载，核对 ZIP 和库的 SHA-256、BuildID、AArch64 ABI、API 35、HMI
及三个 ICD 导出和系统动态依赖；保留二进制原始字节，不修改驱动声明或伪装扩展支持。
源提交、校验值见 `upstream.json`；上游原始构建记录保留在新包 `upstream/`，本包自己的
`VALIDATION.json` 记载本机全局运行失败和原厂对照结果。构建时的 GPL/系统调用例外、MIT、Mesa
许可证声明随包保留；`licenses/Mesa` 来自固定 Mesa 提交，官方源码来源见上游 SOURCE.json。

原旧模块将同一 arm64 库挂到 32 位目录，并在卸载时尝试写回不存在的 old_mali.so；
这两项已移除。新库在安装及启动时检查校验值和最低 SDK，错误时保留原厂 HAL。
支持自选 ICD 的应用需要各自验证；本包不保证普通 Android 游戏可加载自选 ICD。

如需从新驱动回退，可在 Root 管理器禁用此模块并重启，或安装上述原厂回退包再重启。
旧 wrapper1 也可将模块目录 `driver.conf` 中的 `enable_global=1` 改为 `0` 后重启。
wrapper2 在已知失败的平台阻止全局替换，即使配置被改为 `1` 也会保留原厂。

本地打包新驱动：`python3 scripts/prepare-driver.py`（或 `--archive 官方adpkg.zip`），
然后运行 `python3 scripts/package.py`。驱动二进制只出现在忽略的 `driver-dist/` 和产物
ZIP 中，不进入源码 Git 历史。
