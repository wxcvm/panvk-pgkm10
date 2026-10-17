# WSI7 微信公众号页面 A/B 验证（2026-10-17）

## 目的

验证 `RC3-anbfix3-wsi7`（补丁 030，`MOVECERT_ACQ_REPLAY`）是否修复
「微信打开公众号即卡死」的问题，并保留同驱动、同页面、仅切换开关的 A/B 对照。

## 环境

| 项 | 值 |
|---|---|
| 设备 | OnePlus PGKM10 / OP5565 / Android 17（SDK 37）/ Mali-G610 MC6 |
| 微信 | 8.0.79（versionCode 3182） |
| 驱动 | `wsi7`，SHA256 `9c0df1a352a9100da6fb9dfde1533486a736c58d625719f6edc54ad614ef5aec`（仓库 commit `1f59ef0` 构建，与原构建逐字节一致） |
| 原厂对照 | `/vendor/lib64/hw/mt6895/vulkan.mali.so` = `2ae46e5c…50c5b0` |
| 注入方式 | `tools/wechat-ab/start-wsi7-wechat.sh`：把驱动与 ColorX 兼容副本 bind 进 zygote64 命名空间，微信启动后立即把 zygote/init 恢复原厂，仅微信进程保留 PanVK |
| 诊断开关 | `debug.mesa.movecert.sync.trace=true`（记录，不改变同步语义）、`debug.mesa.movecert.afbc.align=true` |
| 变量 | `debug.mesa.movecert.acq.replay` = **1（实验）** / **0（对照）** |

## 操作路径

微信启动 → 聊天列表点击「公众号」条目 → 进入
`com.tencent.mm/...plugin.brandservice.ui.flutter.BizFlutterTLFlutterViewActivity`
（即此前卡死的那一页）→ 连续上滑 5 次 → 每 2 秒用 `uiautomator dump` 探测 UI 是否存活。

## 结果

| 检查 | `acq.replay=1` | `acq.replay=0`（对照） |
|---|---|---|
| 进入公众号 Flutter 页面 | 成功，焦点为该 Activity | 成功，焦点为该 Activity |
| `event=acquire-replay` | **14 次**（补丁 030 路径实际命中） | 0 次 |
| 页面首次渲染后 8 秒 `uiautomator dump` | 成功 | 成功（页面刚打开时） |
| 5 次滑动 + 每 2 秒 dump | **5/5 成功**，内容确实滚动（文章标题从「星穹铁道工坊+」变为「四川大学锦江学院 / 订阅精选 / 黑马程序员」） | — |
| 等待状态机 | `wait` → `callback` → `callback-end` → `driver-done` 正常完成 | `MoveCertSync event=wait … state=0 … timeout=18446744073709551615` 后仅 `condition`，**无 callback** |
| 界面是否冻结 | 否（持续可交互） | **是**：`uiautomator dump` 两次（间隔 12 秒）均无输出 |
| 新增 ANR / tombstone | 无 | 无（短窗口内 ANR 尚未落盘，但 UI 已冻结） |

关键日志（对照，`acq.replay=0`，18:05:32）：

```
MoveCertQueue: n=14 event=final queue=0x78cdcac700 mode=1 submit=0x797bccb000 waits=1 signals=2 commands=1
MoveCertSync : n=24 event=wait sync=0x765f25b168 state=0 owner=0x0 wait=0x0 targets=0,0,0 timeout=18446744073709551615
MoveCertSync : n=25 event=condition sync=0x765f25b168 state=0 owner=0x0 wait=0x0 targets=0,0,0 timeout=18446744073709551615
                                                                       ← 此后没有该对象的 callback
```

实验组（`acq.replay=1`，18:02:37）：

```
MoveCertQueue: n=773 event=acquire-replay queue=0x7ae247ed00 submit=0x764c638080 sem=0x764c63a4c0 sync=0x75f69c46c0
MoveCertQueue: n=774 event=wait-temp      queue=0x7ae247ed00 submit=0x764c638080 sem=0x764c63a4c0 sync=0x75f69c46c0
MoveCertQueue: n=776 event=submit         ... waits=1 signals=2 commands=1
MoveCertQueue: n=777 event=final          ... waits=1 signals=2 commands=1
MoveCertSync : n=1566 event=wait  sync=0x75f6944048 state=1 … timeout=2356795263139
MoveCertSync : n=1567 event=callback      sync=0x75f6944048 state=2 …   ← 正常完成
```

## 结论与边界

- 在本次场景（微信 8.0.79 / 公众号 Flutter 信息流页 / 连续滑动）中，
  `acq.replay=1` **消除了此前可稳定复现的永久等待**，`acq.replay=0` 同驱动仍然冻结。
- 这验证的是「重复等待同一 acquire 二值信号量」这一具体兼容处理，不是完整 Vulkan
  语义修复；补丁仍**默认关闭**，不用于全局安装。
- 未覆盖：长时间浸泡（仅 ~1 分钟交互）、公众号文章正文页（XWeb）、视频号、
  全局替换后的 SurfaceFlinger/ColorX 路径、游戏。
- 测试结束后已恢复原厂驱动与属性，并核对 init/zygote/WebView 命名空间哈希
  （`2ae46e5c…` / `3835dd76…`）。
