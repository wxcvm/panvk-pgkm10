# 全局启用首次通过：wsi7 开机验证（2026-10-17）

## 目的

用**开机路径**（KernelSU 模块 post-fs-data）把 wsi7 驱动与 ColorX 兼容副本
系统级挂载，验证「全局启用」是否还能稳定开机、微信/系统 UI 是否正常、
以及之前必崩的 ColorX 路径是否改善。测试模块带失败安全（3 次未成功启动自动禁用）。

## 环境与配置

| 项 | 值 |
|---|---|
| 设备 | OnePlus PGKM10 / Android 17（SDK 37）/ Mali-G610 MC6 |
| 驱动 | wsi7，SHA256 `9c0df1a3…ef5aec`（新仓库 `1f59ef0` 构建，与原 wsi7 逐字节一致） |
| ColorX 兼容副本 | 本机生成的 `colorx-excluded.so`，SHA256 `16c93822…0b0b8` |
| 挂载 | `/vendor/lib64/hw/mt6895/vulkan.mali.so`、`/system_ext/lib64/libvulkanextimpl.so` |
| 属性 | `debug.mesa.movecert.acq.replay=true`、`afbc.align=true`、`sync.trace=true` |
| SF 后端 | 保持 `skiagl`（**未**改 `debug.renderengine.backend`，即合成器仍用 OEM GLES） |
| 模块 | `tools/global-test/`（`panvk-wsi7-global-test`），失败安全：连续 3 次未 `boot_completed` 则 `disable` |

## 结果

### 开机稳定性（两次冷启动）

| 启动 | 结果 |
|---|---|
| 第 1 次 | `post-fs-data` 校验 OEM 哈希 → 挂载 wsi7 → `service.sh` 在 30 秒看到 `boot_completed=1` 并写 `boot-ok` |
| 第 2 次 | `post-fs-data` 检测到 `boot-ok` → 重置 attempt → 重新挂载 → 32 秒 `boot_completed=1` |
| adb 可用 | 两次均约 45–60 秒上线，未出现开机循环或需要人工干预 |

命名空间核对（第 1 次启动后）：`init`、`zygote64`、`com.android.launcher` 均
`sha256 = 9c0df1a3…`，即全机应用确实从 wsi7 加载；`surfaceflinger` 的 Vulkan 映射为 0（保持 OEM GLES 合成）。

### 应用表现

| 检查 | 结果 |
|---|---|
| 系统 UI / 设置 | 正常渲染（截图核对：图标、文字、列表无错位/花屏） |
| 微信 8.0.79 → 服务号信息流（Flutter 页） | 正常渲染与滚动，图文清晰 |
| 微信驱动日志 | `event=acquire-replay` 16 → 29 次；`timeout=18446744073709551615` 计数 **0**；无 ANR |
| 星穹铁道（`com.HoYoverse.hkrpgoversea`） | 启动进入 ComboSDK 登录界面并保持 60 秒，**未再出现 ColorX `constructFragmentShadingRatesInfo` SIGSEGV**，无新 tombstone |
| 崩溃汇总 | 全程无新增 tombstone；ANR 目录最新仍是 03:00 的旧记录 |

### 回滚

`touch /data/adb/modules/panvk-wsi7-global-test/disable` 并重启后核对：
`/vendor` = `2ae46e5c…`、`/system_ext` = `3835dd76…`、诊断属性为空、`debug.renderengine.backend=skiagl`，
系统正常进入桌面。

## 边界与后续

- 本轮交互窗口约 10 分钟，未做长浸泡、未进入游戏实际画面（停在登录 SDK），
  未验证相机/视频/银行类应用、10-bit（P010）视频合成，也未开启 `skiavk` 合成器。
- 之前 SurfaceFlinger 的 P010 纹理失败条件是 **SF 用 Vulkan 合成（`debug.renderengine.backend=skiavk`）+ P010 缓冲区**；
  本轮 SF 保持 GLES，因此未覆盖该路径。补丁 026（mapper 前置查询）理论上修复 P010 属性查询，
  需要单独在 `skiavk` 下用 10-bit 视频复测。
- 测试模块仅为验证工具，默认应保持 `disable`；正式交付仍需把全局启用与守卫/回滚合并进发布模块。
