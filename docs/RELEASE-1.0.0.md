# PanVK WSI7 v1.0.0 — PGKM10 / Android 17 稳定版

首个正式版：把已验证的 PanVK 实验驱动打包成可安装、可回滚、带失败安全的 KernelSU 模块。

## 亮点

1. **微信公众号卡死修复**：补丁 030（一次性 Android acquire fence replay）消除提交路径
   的重复等待；`debug.mesa.movecert.acq.replay=true` 下公众号/服务号 Flutter 页与文章页
   正常，`acq.replay=0` 可复现卡死（A/B 已记录）。
2. **系统 UI Vulkan 崩溃修复**（本轮核心）：补丁 034 让所有 gralloc 导入走
   **GPU 非缓存**，消除 Mali `GPU_SHAREABILITY_FAULT`——此前 SystemUI 在锁屏/通知栏
   交互 4–8 秒内必崩（device lost → 黑屏/ANR）。
3. **整机验证通过**：
   - 锁屏/解锁/通知栏压力 200 秒：**GPU fault = 0**，SystemUI 全程存活；
   - 重启重复性：开机 30 秒 `boot_completed`，模块自动挂载，props 正确；
   - 15 分钟稳定运行，无新增 tombstone；
   - 微信公众号页渲染正常（截图核对）；
   - 性能 A/B（HWUI Vulkan 滑动）：**非缓存导入无回退**（jank 2.18% vs 2.62%，
     p90 17ms vs 19ms）。

## 包内容

| 文件 | 说明 |
|---|---|
| `vulkan.mali.so` | PanVK WSI7 驱动（Mesa 26.3-devel + 补丁 019–034），sha256 `e62177fb…` |
| `module.prop` | 模块信息（v1.0.0-wsi7，versionCode 10） |
| `driver.conf` | `enable_global` / `scope` / 驱动选项；默认关闭（opt-in） |
| `common.sh` | 平台与 OEM 哈希校验；**设备本机生成 ColorX 兼容副本**（不分发 OEM 代码） |
| `post-fs-data.sh` / `service.sh` | 开机挂载（system 作用域）与 boot 成功标记、失败安全（3 次未完成自动回退） |
| `action.sh` | KernelSU 操作按钮切换启用/禁用（下次开机生效） |
| `PACKAGE-VALIDATION.json` | 驱动哈希、补丁清单、验证摘要 |

ZIP sha256：`d5bbbdfc7e097c50499473ec756d9c7d44f015e2f0d5d0a0287d9411a0877fe6`
（6,553,965 B）

## 要求与安装

- OnePlus PGKM10 / Android 17（SDK 37）/ KernelSU；
- 安装 ZIP → 重启（默认仍是 OEM Vulkan）→ 模块「操作」按钮切换 `enable_global=1`
  → 再重启；`scope=system` 才会让系统 UI 也走 PanVK（验证过的组合需要
  `hwui_use_vulkan` 且其 `debug.renderengine.backend=skiagl`）；
- 回滚：禁用 `MTK_D8100_Vulkan1.4.Panvk`（与 `hwui_use_vulkan`）→ 重启。

## 已知边界

- **SurfaceFlinger RenderEngine 必须保持 `skiagl`**：压缩 YU10（10-bit 视频）的 Vulkan
  导入尚未实现，`skiavkthreaded` 会在解锁界面触发 SF 纹理创建失败；
  下一个测试版将补齐该能力（见 `docs/BETA-SKIAVKTHREADED-PLAN.md`）。
- 导入缓冲默认 GPU 非缓存（修复 shareability 必需的权衡）；可用
  `debug.panvk.kbase.import_clear=0x200000` 做 A/B。
- 游戏只验证到登录界面；未能做长时游戏帧率与 10-bit HDR 视频合成验证。
- 实验性驱动，仅供本机使用；请保留回滚手段。

## 验证环境

`OnePlus PGKM10 / Android 17 (CP2A.260605.016) / Mali-G610 MC6 / kbase CSF uAPI 1.18`。
详细诊断、实验与验证记录见 `docs/SHAREABILITY-FAULT-DIAGNOSIS.md`、
`docs/GLOBAL-BOOT-VALIDATION-2026-10-17.md`、`docs/GLOBAL-APPS-SOAK-2026-10-17.md`。
