# Vulkan 驱动微基准（提交开销 / 清屏吞吐）

`gpu-vk-bench.c` 在本进程内直接 `dlopen` 指定的 Vulkan HAL/ICD（OEM 的
`/vendor/lib64/hw/mt6895/vulkan.mali.so` 或实验驱动的 `.so`），创建独立的
instance/device/图像，测量：

- `small_clear_512x512`：400 次「提交 + fence 等待」，取值反映**提交往返开销**；
- `large_clear_2048x2048`：60 次同样的清屏，反映**GPU 写带宽**。

不修改系统挂载/属性，不接触显示缓冲区。

## 构建与运行（设备端）

需要 Android Vulkan 头文件（Termux clang 自带头文件即可）：

```sh
cd /data/local/tmp/movecert-gpu-probe
export LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib
/data/data/com.termux/files/usr/bin/clang -std=c11 -O2 -Wall -I include \
    gpu-vk-bench.c -o gpu-vk-bench -ldl
```

运行：

```sh
export LD_LIBRARY_PATH=/vendor/lib64/egl:/vendor/lib64:/system/lib64:/system_ext/lib64
export MESA_SHADER_CACHE_DISABLE=true
./gpu-vk-bench /vendor/lib64/hw/mt6895/vulkan.mali.so            # OEM
./gpu-vk-bench /data/local/tmp/movecert-rc3-anbfix3-wsi7.so      # wsi7
```

输出示例：

```
Device=Mali-G610 MC6 API=1.4.363 driver=109060195
small_clear_512x512: iterations=400 elapsed=167.54 ms per_submit=0.419 ms clear_throughput=2.50 GB/s
large_clear_2048x2048: iterations=60 elapsed=32.82 ms per_submit=0.547 ms clear_throughput=30.68 GB/s
```

## 2026-10-17 基线（PGKM10，3 轮交替，取中位数）

| 指标 | OEM（Mali 驱动） | wsi7（PanVK） | 变化 |
|---|---|---|---|
| 512×512 每次提交 | 0.562 ms | **0.419 ms** | **−26%** |
| 512×512 清屏吞吐 | 1.92 GB/s | **2.50 GB/s** | **+30%** |
| 2048×2048 每次提交 | 0.781 ms | **0.536 ms** | **−31%** |
| 2048×2048 清屏吞吐 | 21.48 GB/s | **31.30 GB/s** | **+46%** |

细节：OEM `per_submit` 0.545–0.634 ms，wsi7 0.405–0.432 ms（小）；OEM 0.687–0.782 ms，
wsi7 0.525–0.547 ms（大）。

## 边界

- 这是驱动层微基准，不代表真实应用/游戏帧率；仅说明 wsi7 在提交路径和 GPU 写带宽上
  **没有相对 OEM 的性能回退**，本机测得反而更快。
- 结果受温度/频率影响；对比时应交替运行并取多轮中位数（本表已如此）。
- 需要更贴近实机的指标（应用冷启动、游戏帧率）时另行测量。
