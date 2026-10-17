# 微信 A/B 验证脚本（设备侧）

这些脚本在手机上以 root 运行，把一个实验 ICD 临时注入 **zygote64 的挂载命名空间**，
使随后启动的微信进程加载 PanVK + ColorX 兼容副本；微信启动完成后立刻把
zygote/init 命名空间恢复为原厂，因此系统其余部分（SurfaceFlinger、系统 UI 等）
始终使用原厂 Vulkan。

## 前置条件

- OnePlus PGKM10 / Android 17（SDK 37），KernelSU root，busybox 位于
  `/data/adb/ksu/bin/busybox`。
- 驱动 `.so` 与 ColorX 兼容副本已按脚本中的 SHA256 放到 `/data/local/tmp/`：
  - `/data/local/tmp/movecert-rc3-anbfix3-wsi7.so`
  - `/data/local/tmp/movecert-colorx-excluded.so`
- `/data/local/tmp/check-wsi2-baseline.sh` 存在（枚举所有挂载命名空间并核对原厂哈希）。

## 用法

```sh
# 实验组：开启 MOVECERT_ACQ_REPLAY
su -c 'sh /data/local/tmp/start-wsi7-wechat.sh 1'

# 对照组：关闭 MOVECERT_ACQ_REPLAY（同一驱动）
su -c 'sh /data/local/tmp/start-wsi7-wechat.sh 0'

# 任何时刻恢复（脚本内部 trap 也会调用；watchdog 600 秒后兜底）
su -c 'sh /data/local/tmp/restore-wsi7-wechat.sh "$(cat /data/local/tmp/movecert-wsi7-wechat-session)"'
```

启动脚本会：核对驱动/兼容副本 SHA → 确认 zygote 命名空间独立且 `/vendor`、
`/system_ext` 未被 shared 传播 → 设置诊断属性 → bind 两个文件 → 核对 init 仍为原厂
→ 清空并开始 logcat 采集（`/data/local/tmp/movecert-wsi7-logcat.log`）→ 启动微信
→ 核对微信进程内驱动哈希 → 恢复 zygote/init → 记录 session 目录（包含原始属性值、
zygote pid/ns、应用 pid）。

## 结果判读

- 成功：`uiautomator dump` 持续可用；日志出现 `event=acquire-replay`；等待有
  `callback`/`callback-end`/`driver-done`。
- 失败：`MoveCertSync event=wait … state=0 … timeout=18446744073709551615` 之后
  只有 `condition`，没有 `callback`；`uiautomator dump` 无输出。

完整记录见 `docs/WSI7-WECHAT-VALIDATION.md`。

## 注意

- 仅用于实验验证；不要把这些挂载写进开机配置。
- `restore` 会 force-stop 微信并恢复属性；若进程崩溃导致 trap 未执行，
  watchdog 也会在 10 分钟后恢复。
- 驱动与兼容副本必须逐字节校验一致后再绑定。
