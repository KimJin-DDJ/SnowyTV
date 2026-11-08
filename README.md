# SnowyTV

在 **Chromecast with Google TV (HD)** 上安装并测试社区版 Kazumi TV。这里维护安装脚本和测试说明。安装使用上游发布的 `2.3.8-tv.1`、32 位 `armeabi-v7a` APK，保留其原签名。纯投屏型 Chromecast 无法安装 Android APK。 [发布说明](https://github.com/LeoLee0812/Kazumi-TV/releases/tag/2.3.8-tv.1) · [对应版本源码](https://github.com/LeoLee0812/Kazumi-TV/tree/2.3.8-tv.1)

## 直接在电视上安装

1. 在电视首页搜索并安装 **Downloader by AFTVnews**。 [Google Play](https://play.google.com/store/apps/details?id=com.esaba.downloader)
2. 打开 Downloader，把下方地址填入网址框，然后按 **Go**。也可以用同一 Wi-Fi 下的手机 Google Home 遥控器粘贴网址。 [Google 手机遥控说明](https://support.google.com/chromecast/answer/11221499)

   ```text
   https://github.com/LeoLee0812/Kazumi-TV/releases/download/2.3.8-tv.1/Kazumi-TV_2.3.8-tv.1_armeabi-v7a.apk
   ```

3. 若电视询问安装权限，在弹出的设置里为 Downloader 开启 **允许来自此来源**。返回后点 **安装 → 打开**。如果安装提示已关闭，从 Downloader 的 **Files** 中重新打开 APK。
4. 如果系统隐藏了安装权限，在 **设置 → 系统 → 关于 → Android TV OS 版本号（Android TV OS build）** 上连续按七次确认键，开启开发者模式，再回到 Downloader 安装。 [Chromecast 侧载步骤](https://github.com/yuliskov/SmartTube#installation-chromecast-with-google-tv)

## 用 Mac 或 Linux 一条命令安装

首次设置时，让电脑和电视连到同一 Wi-Fi，开启电视的开发者模式，并安装 Android SDK Platform-Tools，让 `adb` 在 `PATH` 上。若下载 ZIP 并解压到「下载」目录，可先运行 `export PATH="$HOME/Downloads/platform-tools:$PATH"`。 [Platform-Tools 下载](https://developer.android.com/tools/releases/platform-tools#downloads)

如果电视有 **设置 → 系统 → 开发者选项 → 无线调试**，选择 **使用配对码配对设备**。把下方示例换成配对弹窗显示的地址，再按提示输入电视上的配对码。 [Android 官方无线调试指南](https://developer.android.com/tools/adb#connect-to-a-device-over-wi-fi)

```bash
adb pair 192.168.1.42:37123
```

退出配对弹窗，在 **无线调试主页面** 查看安装用的 IP 和端口。该端口通常和配对端口不同。把下方示例换成主页面地址。

```bash
git clone https://github.com/KimJin-DDJ/SnowyTV.git
cd SnowyTV
bash install-tv.sh 192.168.1.42:40123
```

如果 `adb devices -l` 已列出唯一已连接的电视，直接运行 `bash install-tv.sh`。有多个设备时，可将目标电视的序列号作为参数。若电视没有无线调试菜单，可以走上面的 Downloader 流程。

脚本检查目标设备是否支持 Android TV 和 `armeabi-v7a`，下载并校验固定版本的 APK，再执行覆盖安装。可以用 `SNOWYTV_APK=/path/to/file.apk bash install-tv.sh` 使用同一版本的本地 APK。若电视提示签名冲突，先备份收藏和观看记录，再决定是否卸载已有的 Kazumi。 [上游安装说明](https://github.com/LeoLee0812/Kazumi-TV#安装)

## 电视上怎么测

1. 在 **你的应用** 中打开 **Kazumi TV**，用遥控器方向键切换焦点，确认能进搜索并返回。
2. 搜索 **凡人修仙传**，进入详情后选择 **开始观看 → MXdm**，打开片源里的对应条目，试播 **线路 1 → 第 199 集**。如果没搜到，试用不含「年番」的关键词。片源可用性以电视上实际结果为准。
3. 确认有画面和声音，并试一下暂停、继续、快进和切集。
