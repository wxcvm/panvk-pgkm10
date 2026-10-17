# P010 / YU10 独立探针

两个探针在**独立进程**中直接 `dlopen` 指定 Vulkan HAL/ICD 并创建
1272×2772 的 AHardwareBuffer，用来区分 AHB 属性查询与导入/视图创建是否可用：

- `gpu-p010-properties-probe.c`：创建缓冲区后查询
  `vkGetAndroidHardwareBufferPropertiesANDROID`，覆盖三种格式/usage 组合；
- `gpu-p010-import-probe.c`：在属性查询基础上进一步 `CreateImage`、
  `AllocateMemory`、`BindImageMemory`、创建 YCbCr conversion 与 `CreateImageView`。

`gpu-hal-loader.h` 是加载 OEM Vulkan HAL（`HMI` 入口）的最小 ABI 声明；
加载 ICD `.so` 时优先用 `vkGetInstanceProcAddr` / `vk_icdGetInstanceProcAddr`。

## 构建（设备端，Termux clang）

```sh
cd /data/local/tmp/movecert-gpu-probe
export LD_LIBRARY_PATH=/data/data/com.termux/files/usr/lib
/data/data/com.termux/files/usr/bin/clang -std=c11 -O2 -Wall -I include \
    gpu-p010-properties-probe.c -o gpu-p010-properties-probe -ldl
/data/data/com.termux/files/usr/bin/clang -std=c11 -O2 -Wall -I include \
    gpu-p010-import-probe.c -o gpu-p010-import-probe -ldl
```

`include/vulkan` 头文件需事先放到该目录（Termux 或 NDK 自带的 Vulkan 头均可）。

## 运行

```sh
export LD_LIBRARY_PATH=/vendor/lib64/egl:/vendor/lib64:/system/lib64:/system_ext/lib64
export MESA_SHADER_CACHE_DISABLE=true
./gpu-p010-import-probe /vendor/lib64/hw/mt6895/vulkan.mali.so        # OEM
./gpu-p010-import-probe /data/local/tmp/movecert-rc3-anbfix3-wsi7.so  # 实验驱动
```

## 2026-10-17 结论

线性 P010（usage `0x100`）在 wsi7 上属性查询与导入/视图创建全部成功；
`usage 0x400900` 的压缩 YU10 仍返回 `VK_ERROR_INVALID_EXTERNAL_HANDLE`。
详见 `docs/P010-AND-PERF-2026-10-17.md`。
