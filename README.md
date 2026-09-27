# MacDou

原生 macOS 菜单栏工具：开口电量环、中央 Wi-Fi、可配置的底部四点，以及整合的 4G 随行模块。

## 安装与使用

需要 Apple Silicon Mac、macOS 26 或更新版本。构建需要 Apple Command Line Tools、现有的 libusb 开发文件（默认 `/opt/homebrew/opt/libusb`，也可设置 `LIBUSB_PREFIX`）。

```sh
bash scripts/build-app.sh
ditto dist/MacDou.app /Applications/MacDou.app
open /Applications/MacDou.app
```

左键点击图标打开状态面板，右键快速选择四点内容。圆环右上角在充电时显示闪电，接电但未充电（包括已充满）时显示插头；左上角的叶片表示低电量模式。剩余电量 ≤20% 时菜单栏文字显示“低电量”，≤10% 或系统发出最终低电量警告时显示“电量危急”。系统提前发出低电量警告时也会显示；低电量模式会另外显示“低电量模式”。面板用文字区分充电中、已充满、接电未充电、低电量和低电量模式。浅色电量底轨始终可见。无内置电池时仅保留底轨。

点击面板中的电量区域，可查看供电、充电和低电量模式状态，并进入 macOS 电池设置调整电源模式。点击 Wi-Fi 行，可在 MacDou 中开关无线网、查看连接与信号、扫描附近网络并切换连接；已保存网络会先尝试直接连接，需要密码时再输入。企业网络的账号、证书和其他高级选项由系统网络设置处理。扫描网络名称时 macOS 会要求定位权限：MacDou 只在进入 Wi-Fi 页且已获授权，或点击“扫描”后读取附近网络，不在后台扫描。密码只用于本次连接，不保存到 MacDou 设置。

电池与 Wi-Fi 详情页提供“菜单栏图标…”入口；如果要让 MacDou 图标代替系统的电池、Wi-Fi 图标，请在 macOS“系统设置 → 菜单栏”中取消显示原图标。macOS 控制中心和系统设置仍可随时使用。

要调整图标顺序，按住 **⌘ Command** 拖动 MacDou 图标到菜单栏右侧。macOS 会记住位置；系统时钟和控制中心占用最右侧区域。

安装到 `/Applications` 后，可在“4G 设置”中打开“登录后自动启动 MacDou”。也可运行 `/Applications/MacDou.app/Contents/MacOS/MacDou --enable-login`；若输出 `requiresApproval`，需在“系统设置 → 通用 → 登录项与扩展”中批准。用 `--login-status` 可检查当前状态。

## 四点与 4G

| 四点模式 | 含义 |
| --- | --- |
| 系统音量（默认） | 每点约 25%，静音时全浅 |
| Wi-Fi 信号 | RSSI 四档，≥ −55、−56～−67、−68～−75、＜ −75 dBm |
| 4G 信号 | 模块 0–4 格，优先 RSRP、缺失时回退 RSSI |
| CPU 使用率 | 两次系统 CPU 计数之差，每点约 25% |
| 内存占用 | 活跃、驻留和压缩内存占物理内存的比例 |
| 隐藏四点 | 只显示电量与 Wi-Fi |

主页的“4G 随行”卡片进入完整蜂窝页面：信号、运营商、网卡、上下行网速、流量曲线和可展开的模块详情（固件、注册、RSRP/RSSI/RSRQ/SINR、网关和 USB 模式）。页面顶部可打开原生网卡模式与短信窗口，也能刷新；下方可检测外网、尝试恢复连接、导出诊断，以及设置自动恢复、菜单栏网速、登录启动。右上角偏好设置负责图标外观。设置自动保存。

MacDou 使用同一作者的 [4G Companion（原 DJI4GGuard）](https://github.com/fanfanv5/4g-companion) 中的 USB AT 模块、网卡采样、SMS 解码和模式管理代码；模块 helper 由 `Native/modem-helper.c` 构建。构建会将 libusb 动态库及其 LGPL-2.1 许可证封入 App。模块、SIM、运营商和模式兼容性范围详见原项目 README。模式切换需单独勾选和确认。

### 短信收件箱

在“4G 随行”页面点“短信”，窗口会自动读取模块存储 **ME**。如果短信保存在 SIM 卡，切换到 **SM** 后会自动加载，无需再点读取。左侧按发件人、时间和摘要列出收到的短信；点选一条，右侧查看完整正文。默认先尝试保留未读状态。如果界面提示固件不支持，勾选“保留未读失败时，允许模块标记已读”后会自动重试；这可能改变模块内的未读状态，但不会删除短信。

“刷新短信”可随时手动更新。“此窗口打开时每 15 秒刷新”默认关闭；开启后只在短信页显示期间刷新，并沿用当前的标记已读许可。“清空显示”只清空当前窗口，不删除模块或 SIM 卡中的短信。关闭窗口或 Mac 睡眠后，界面中的短信会清空；再次打开短信页会自动加载。当前短信功能只读，不发送短信，也不将短信写入诊断日志。模块在电脑睡眠期间能否收信取决于 USB 供电、固件和运营商。

如果原 4G 随行还在运行，MacDou 的 4G 页面会提供“退出 4G 随行并接管”按钮，在此之前暂停模块 AT 读取和恢复。旧 App 的文件和设置保留。新 App 首次启动继承旧版自动恢复及网速显示偏好；登录启动由 MacDou 设置单独控制。

### 后台采样与系统通知

面板打开时系统状态和 4G 网卡每 2 秒采样。面板关闭后，系统状态按四点来源调整：CPU 每 2 秒，音量、Wi-Fi 信号或内存每 5 秒，4G 信号或隐藏四点每 10 秒；音量、CPU 和内存只读取当前选中的一项。4G 网卡在菜单栏显示实时网速时仍每 2 秒采样，否则有模块时每 5 秒、无模块时每 10 秒采样。模块信号随网卡巡检读取，但至少间隔 5 秒；读取失败 12 秒后显示为未知。4G 网卡就绪时约每 30 秒检查一次模块网关。短信只在打开短信页时自动读取；每 15 秒刷新需单独开启。

Wi-Fi 路径变化由 `NWPathMonitor` 通知，睡眠、唤醒和解锁由系统工作区通知，低电量模式切换由 `ProcessInfo` 通知；这些事件会触发相应刷新。电池状态使用 IOKit、Wi-Fi RSSI 使用 CoreWLAN、音量使用 CoreAudio、CPU/内存使用 Mach API 定时读取。Mac 睡眠时暂停定时采样，唤醒后恢复；打开面板也会立即刷新。部分输出设备没有系统音量读数，未知的音量或信号显示浅色点。

## 验证

```sh
bash scripts/test.sh
bash scripts/test-cellular.sh
swift run MacDou --diagnose
dist/MacDou.app/Contents/MacOS/MacDou --diagnose-cellular
swift run MacDou --render-preview /tmp/macdou-charging.png --charging-preview
swift run MacDou --render-preview /tmp/macdou-plugged.png --plugged-preview
swift run MacDou --render-preview /tmp/macdou-low.png --low-battery-preview --low-power-preview
swift run MacDou --render-preview /tmp/macdou-cellular.png --cellular-preview
swift run MacDou --render-preview /tmp/macdou-cellular-full.png --cellular-preview --full-cellular-preview
swift run MacDou --render-preview /tmp/macdou-settings.png --settings-preview --dark-preview
dist/MacDou.app/Contents/MacOS/MacDou --render-preview /tmp/macdou-battery-page.png --battery-page-preview
dist/MacDou.app/Contents/MacOS/MacDou --render-preview /tmp/macdou-wifi-page.png --wifi-page-preview
```

4G 离线回归使用模拟 AT 事务、人工构造短信和网卡计数器，不读取真实短信或切换 USB 模式。`--render-preview` 用示例数据渲染实际界面。`--diagnose` 只输出本机系统传感器的汇总，`--diagnose-cellular` 通过本机 helper 读取模块状态并仅输出脱敏后的布尔状态与信号格。实际短信读取、USB 模式切换及睡眠唤醒恢复需单独验证。

本机构建为临时签名；对外分发需 Developer ID 签名和公证。`mac-status-ring-concept.svg` 为设计稿，应用的菜单栏图形由 `RingRenderer` 绘制。

## 许可证

MacDou 源码采用 [MIT 许可证](LICENSE)。构建时打包的 libusb 使用 LGPL-2.1-or-later，详见 [第三方软件说明](THIRD-PARTY-NOTICES.md)。仓库不包含签名证书、本机诊断数据或应用构建产物。
