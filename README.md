# Kindle 投放 · Kindle as Display

把 Kindle DX Graphite 变成一块按需更新的墨水屏。Mac 将你选择的文件、剪贴板内容或截图转换为 **824 × 1200 灰阶画面**，经 USB 投放。每次发送更新一页，适合放参考图、文档和待办事项。

## 准备

- **Mac**：Apple 芯片，macOS 14 或更新版本。使用 Apple Command Line Tools 从源码构建。
- **Kindle**：已在 **Kindle DX Graphite（DXG，型号前缀 B009）** 真机验证文件和截图投放。需要已启用的 USBNetwork、可登录的 root SSH，以及固件自带的 `/usr/sbin/eips` 和 `powerd`。其他 Kindle 型号尚未验证。
- **连接**：使用支持数据传输的 USB 线。App 使用 Kindle 的 USB 地址 `192.168.2.2`。

## 1. 配置 Kindle USBNetwork

如果 Mac 终端已经能运行 `ssh root@192.168.2.2` 登录这台 Kindle，可直接跳到[构建与安装](#2-构建与安装-mac-app)。

1. 在 Kindle 的设置页确认型号和固件。按 NiLuJe 的说明安装与 **DXG** 和你的固件匹配的 JailBreak 与 USBNetwork。下载后阅读压缩包内的安装说明，按该版本的方式安装。 [NiLuJe 的旧款 Kindle 安装说明](https://www.mobileread.com/forums/showthread.php?t=88004)
2. 启用 USBNetwork 并用 USB 线接到 Mac。旧版固件 2.x 可在 Kindle 主屏幕的搜索框中分别执行 `;debugOn` 和下面的命令。成功时 Mac 会看到新的 USB 以太网接口。 [USBNetwork 的操作说明](https://github.com/azuwis/kindle-usbnetwork/blob/0.33.N/README_FIRST.txt)

   ~~~text
   `usbNetwork
   ~~~

3. 在 Mac 打开 **系统设置 → 网络**，选择新出现的 USB 以太网服务，进入 **详细信息 → TCP/IP**，将「配置 IPv4」设为「手动」。Mac 的 IP 填 `192.168.2.1`，子网掩码填 `255.255.255.0`，路由器留空。Kindle 的 USB IP 应为 `192.168.2.2`。 [Apple 的 TCP/IP 设置说明](https://support.apple.com/guide/mac-help/mh14129/mac)
4. 从 Mac 终端登录。首次连接时，核对并信任这台 Kindle 的 SSH 主机密钥，然后退出。App 使用这条已保存的主机记录进行校验。App 支持已配置的 SSH 公钥，或 USBNetwork 在 USB 直连模式下允许的空密码。

   ```sh
   ssh root@192.168.2.2
   ```

   登录后可运行以下命令检查设备。竖屏 DXG 应输出 `824,1200`，状态通常为 `active` 或 `screenSaver`。

   ```sh
   test -x /usr/sbin/eips && cat /sys/class/graphics/fb0/virtual_size
   lipc-get-prop -s com.lab126.powerd state
   exit
   ```

## 2. 构建与安装 Mac App

首次构建前安装 Apple Command Line Tools。如果 Mac 已安装 Xcode 或 Command Line Tools，可以跳过此步。 [Apple 的安装说明](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools)

```sh
xcode-select --install
```

安装完成后，在终端运行：

```sh
git clone https://github.com/mayunlei/kindle_as_display.git
cd kindle_as_display
./build.sh
open 'build/Kindle 投放.app'
```

也可以在 Finder 里将 `build/Kindle 投放.app` 拖到「应用程序」文件夹，之后像普通 Mac App 一样打开。构建脚本会给本机构建的 App 签名。

## 3. 投放与退出

| 要做什么 | 操作 |
| --- | --- |
| 投放文件 | 把图片、PDF、TXT 或 Markdown 拖进 App，也可以点「拖入文件，或点击选择」。先看灰阶预览，再点 **投放当前页**（`⌘↩`）。 |
| 投放 PDF 或长文的一页 | 用预览旁的箭头选页，再点 **投放当前页**。Markdown 以纯文本显示。 |
| 投放剪贴板 | 复制图片或文字，在 App 内点 **粘贴**（`⌘V`），预览后投放。 |
| 框选截图并直接投放 | 点 **框选并投放**，或在 App 内按 `⌘⇧K`，也可从 Mac 菜单栏进入。拖出截图范围，松手即发送。按 Esc 取消。 |
| 投放宽截图 | 在 App 里选择 **横向**，投放后把 Kindle 向右转 90° 阅读。发送时 Kindle 的阅读界面需处于竖向。 |
| 返回 Kindle 阅读 | USB 已连接时，在 App 内点 **返回 Kindle 阅读界面**。也可以使用 Kindle 自己的唤醒键。 |

第一次框选截图时，在 macOS 的 **系统设置 → 隐私与安全性 → 屏幕录制**（部分版本叫「屏幕与系统音频录制」）为 **Kindle 投放** 开启权限。如系统提示，退出并重开 App。 [Apple 的屏幕录制权限说明](https://support.apple.com/guide/mac-help/mchld6aa7d23/mac)

## 常见问题

- **连不上 Kindle**：用 `ssh root@192.168.2.2` 先验证 USB 连接。检查数据线、USBNetwork 是否开启，以及 Mac 是否为 USB 网卡配置了正确的 IP。若 Kindle 已深睡，先唤醒再投放。
- **SSH 主机密钥校验失败**：在终端确认设备身份和主机密钥。若换过 Kindle 或重新生成过设备密钥，核对新密钥后更新对应的主机记录。
- **终端能输密码登录，App 报登录失败**：App 没有交互式密码输入框。请给 USBNetwork 配置 SSH 公钥并用终端验证该公钥可登录。
- **提示竖屏或未进入屏保**：先返回 Kindle 阅读界面，切换到竖屏，然后重试。
- **截图未完成**：检查屏幕录制权限，并在授权后重开 App。

## 电源与数据

每次投放经 SSH 上传临时 PNG，Kindle 用原厂屏保状态承载画面，并通过 `eips` 刷新一次。传输完成后临时文件会被清理。Kindle 继续使用固件的自动深睡策略，接回 USB 并唤醒后即可再次投放。
