# PanVK 显示诊断

此 APK 用于区分独立离屏绘制和 Android 显示交换链问题。它不是驱动安装包，
不修改系统配置，不请求网络、存储或游戏权限。包名为 `dev.wxcvm.panvkprobe`。

构建通过 `Build PanVK display probe` Actions 完成，使用固定 NDK r28c、
API 35 和已校验 SHA 的 RC3-anbfix3 构建产物。JNI 生命周期探针和着色器来自
固定上游提交 `fd6ed91eff1c8d3a83307a2348b959bb93797011`，下载后再次检查 SHA。
`prepare-source.py` 将背景编码为 8 位帧编号，并按编号移动红色三角形。
PixelCopy 从实际读回画面解码编号，再检查背景和几何是否属于同一帧，避免
静态图案把混帧、旧图形残留误判为正确。上游 MIT 许可随 APK 打包。

两种独立启动方式（切换前必须结束进程，JNI 会缓存加载的库）：

```sh
adb shell am force-stop dev.wxcvm.panvkprobe
adb shell am start -n dev.wxcvm.panvkprobe/.MainActivity --es driver bundled --ez auto true

adb shell am force-stop dev.wxcvm.panvkprobe
adb shell am start -n dev.wxcvm.panvkprobe/.MainActivity --es driver system --ez auto true
```

`bundled` 直接加载 APK 内的实验驱动；`system` 加载当前系统 Vulkan loader。
系统模式并不自动启用实验驱动，需另行核对进程映射才能认定使用了 PanVK。
`--ei delay_ms 15000` 可延迟启动，便于为这个诊断进程准备临时环境。

探针执行 300 帧、调整尺寸、120 帧和 10 次交换链创建/销毁。
主阶段额外通过 PixelCopy 读取自己的 Surface，检查远离边界的编号颜色和移动三角形。
根据交换链实际声明的 `preTransform`（0/90/180/270 度）映射显示坐标，
避免将 Android 的正常逆向预旋转误报为像素异常；其他变换显式报失败。
最终 PASS 要求 JNI 生命周期成功，至少 3 帧像素正确、编号至少变化 3 次，
无异常帧、读回错误或编号逆序。编号每 256 帧循环，采样间隔约 150 ms；
若严重调度停顿导致跨过半个编号周期，逆序告警也可能是采样限制，需要核对日志。
它能发现抽样中的混帧与长时间停滞，但不能测定端到端延迟或排除未抽到的异常。
55 秒未完成将终止诊断进程。结果保存在 App 内部 `files/native.log` 和
`files/result.txt`，可通过 `adb shell run-as dev.wxcvm.panvkprobe cat files/result.txt`
读取。日志不自动上传。

此检查只覆盖简单几何及显示交接；通过也不代表星穹铁道渲染正确。
