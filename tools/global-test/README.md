# 全局启用测试模块（fail-safe）

`panvk-wsi7-global-test` 在开机 `post-fs-data` 阶段把 wsi7 驱动与 ColorX 兼容副本
挂到系统路径，用于验证「全局启用」的启动稳定性和应用兼容性。**仅供验证，不允许
作为日常模块发布。**

## 行为

1. 校验 OEM 文件（`/vendor/.../vulkan.mali.so`、`/system_ext/.../libvulkanextimpl.so`）
   与模块内副本的 SHA256，任一不符即放弃挂载；
2. 记录启动尝试次数：连续 **3 次**未看到 `sys.boot_completed=1` 则自动写 `disable`
   并退出（下一次启动回原厂）；
3. 成功启动由 `service.sh` 写 `boot-ok`，下次启动时重置计数；
4. 设置 `debug.mesa.movecert.acq.replay=true`、`afbc.align=true`、`sync.trace=true`。

## 安装（仅验证用）

```sh
# 1) 把模块目录与两个二进制放到设备
adb push . /data/local/tmp/global-test/
adb shell su -c 'cp -r /data/local/tmp/global-test /data/adb/modules/panvk-wsi7-global-test'
# 2) 放入逐字节校验过的驱动与 ColorX 兼容副本
adb shell su -c 'cp /data/local/tmp/movecert-rc3-anbfix3-wsi7.so /data/adb/modules/panvk-wsi7-global-test/vulkan.mali.so'
adb shell su -c 'cp /data/local/tmp/movecert-colorx-excluded.so     /data/adb/modules/panvk-wsi7-global-test/colorx-excluded.so'
# 3) 重启
adb reboot
```

回滚：

```sh
adb shell su -c 'touch /data/adb/modules/panvk-wsi7-global-test/disable'
adb reboot
```

## 验证结果

见 `docs/GLOBAL-BOOT-VALIDATION-2026-10-17.md`：两次冷启动均 30 秒左右
`boot_completed`，微信服务号页与系统设置渲染正常，星穹铁道不再触发 ColorX 崩溃，
回滚后原厂哈希核对通过。

## 注意

- 必须保持 `debug.renderengine.backend=skiagl`（本模块未修改合成器后端）；
  把 SF 切到 `skiavk` 属于另一条高风险路径，需要单独验证 P010/10-bit 合成。
- 失败安全只能应对「反复开机不完成」；若设备卡在开机动画不自动重启，需要手动长按电源键重启。
