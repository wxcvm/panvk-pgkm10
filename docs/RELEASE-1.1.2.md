# v1.1.2 — 打包修复：service.sh.orig 缺失 + zygote 命名空间注入（2026-10-21）

## 现象

1. KernelSU 管理器里 `MTK_D8100_Vulkan1.4.Panvk` 的**开关点不开**（灰着、点了没反应）。
2. 更新到 v1.1.1 并启用后，模块"看起来打开了"，但**微信等 App 仍在用原厂 Vulkan 驱动**
   （`/proc/<pid>/maps` 里的 `vulkan.mali.so` 仍是 OEM 哈希 `2ae46e5c…`）。

## 根因

### 1. 开关失效：待更新未应用

v1.1.1 是在模块**已安装且被禁用**的状态下安装的，KernelSU 写入
`/data/adb/modules_update/<id>/` 并创建 `update` 标记；手机自 2026-10-20 23:57 之后
未重启（uptime 21.5 小时），待更新一直未应用。该状态下管理器开关不生效
（`ksud module enable` 可正常工作，说明是 UI/状态层面的限制）。

**处理**：重启一次 → KernelSU `handle_updated_modules()` 应用更新（源码确认会保留
`disable` 标记），`update`/`modules_update` 清空，开关恢复可用。

### 2. App 拿不到驱动：打包漏了 `service.sh.orig`

v1.1.1 的模块 ZIP 中 `module/service.sh.orig` **没有被打包**
（`scripts/package-wsi7-module.py` 的 `MODULE_FILES` 漏列），而
`module/service.sh` 末尾是 `exec /system/bin/sh "$MODDIR/service.sh.orig"`。

后果：
- service 阶段执行一个不存在的脚本；
- 负责把 ICD 注入 **App 派生命名空间（zygote/usap）** 的逻辑完全没有执行；
- `scope=system` 只依赖 `post-fs-data` 里的 init 命名空间 bind。本机实测：
  `init` / `system_server` 能看到 wsi7，但 **`zygote64` 在 bind 之前/开机过程中重建了
  命名空间**，因此由它派生出的 App（含微信）仍然使用 OEM 驱动。

## 修复

1. `module/service.sh.orig` 补回并增强：
   - 对 `scope=apps` 与 `scope=system` 都执行 zygote/usap 注入（system 模式下 init
     已由 post-fs-data 绑定，这里只补 App 派生命名空间）；
   - **先绑一次**覆盖早启动的 App，`sys.boot_completed=1` 后再**校验并按需重绑**
     （最多 6 轮，每轮 5 s），应对 zygote64 开机过程中重建命名空间；
   - 正常写入 `boot-ok`，保证 `scope=system` 的 3 次失败自动回退计数器能复位。
2. `scripts/package-wsi7-module.py`：
   - `MODULE_FILES` 增加 `service.sh.orig`，并在产物校验里强制其存在；
   - 默认产物名改为 `PanVK-WSI7-PGKM10-v1.1.2.zip`；
   - 修正驱动来源提交（`bcc8e69…`）与 14 个实际构建补丁清单
     （原先误列了 022–030 诊断补丁）；
   - `PACKAGE-VALIDATION.json` 记录 zygote 命名空间修复与本次实测结果。
3. `module/module.prop`：`version=1.1.2`、`versionCode=14`。

## 实机验证（PGKM10 / Android 17，2026-10-21）

```
post-fs-data: mounted wsi7 system-wide (attempt 1)
service:      early bind: 2/2 app spawn namespaces
              boot completed after 38s
              bound app namespace pid=… name=zygote
              bound app namespace pid=… name=zygote64
              bound app namespace pid=… name=webview_zygote
              post-boot verify round=1: 3/3
              service bind complete: scope=system spawn namespaces=3/3

命名空间驱动哈希（应均为 5eb3899d…）：
  init=5eb3899d  zygote=5eb3899d  zygote64=5eb3899d  system_server=5eb3899d
  WeChat=5eb3899d  vulkan 映射 4 段
本次开机无新增 tombstone / ANR；boot-ok 正常写入。
```

## 配置与回滚

- 当前配置：`enable_global=1`、`scope=system`（用户选择；`scope=apps` 更保守）。
  `scope=system` 下若 SurfaceFlinger 被配置为 Vulkan（需 `hwui_use_vulkan` 模块 +
  `skiavkthreaded`），10-bit 压缩视频可能在解锁画面触发 SF P010 abort；当前该模块
  未安装，SF 保持 `skiagl`。
- 回滚：KernelSU 中禁用/卸载模块并重启，或
  `ksud module disable MTK_D8100_Vulkan1.4.Panvk` + 重启。
