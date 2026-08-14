# macOS 常用功能与命令 · 扩充清单(more-mac-commands)

> 「Mac 小助手」命令速查扩容资料。**与现有 135 条(`CommandLibrary.swift` / `mac-pain-points.md`)去重后**的**新增**条目。
> 联网核实为主,覆盖 **macOS Ventura 13 / Sonoma 14 / Sequoia 15 / Tahoe 26**,标注 Apple Silicon 与 Intel 差异。今天 2026 年。
> 本次共新增 **127 条**,分 14 组;第三方工具另列 16 个;文末附「建议新增功能页/交互点」「与现有 135 条的重叠/替换建议」。

## 使用图例(与现有库对齐)

- **风险等级**:🟢 安全(只读/可逆)· 🟡 需谨慎(改状态 / 需 sudo)· 🔴 危险(可破坏系统 / 不可逆 / 降低安全)。
- 占位符:`<path>` `<pid>` `<bundleid>` `<label>` `en0` `<SSID>` 等,集成时由用户输入/选择替换。
- 表格「命令」列中 `<br>` 表示多行、`\|` 表示管道符 `|`。
- 需管理员权限的带 `sudo`;GUI 里建议用 `osascript -e 'do shell script "…" with administrator privileges'` 弹系统授权框。
- 凡 `defaults write` 改界面/输入的默认项,除注明外均**可逆**(`defaults delete <domain> <key>` 或改回),改完需 `killall` 对应进程。

### ⚠️ 本轮新增里最需要注意的版本/芯片差异

1. **Wi‑Fi 扫描巨变**:`airport` 私有工具在 **Sonoma 14.4 已被移除**;`wdutil info` 需 `sudo` 且 **Sequoia 15+ 会把 BSSID/SSID 打码**;`networksetup -getairportnetwork en0` 在 13/14 能返回 SSID,**15 起被禁用返回空**。真正可用的「扫描附近网络」只能走 CoreWLAN(需 Developer ID 签名 + 定位权限),命令行只能用第三方 `macwifi-cli` 之类。
2. **Apple Silicon 无 NVRAM/SMC 重置组合键**:`nvram` 命令仍在,但没有「PRAM/SMC 重置」概念;恢复模式为「关机后长按电源键」。
3. **录屏 `screencapture -v`**:Catalina 起支持,`-i`(交互)不能与 `-v` 同用;`-g` 才收麦克风;首次需授予「屏幕录制」权限。
4. **控制中心类 `defaults`(电量百分比、时钟秒数等)域从 Big Sur 起变为 `com.apple.controlcenter` / `com.apple.menuextra.*`,Sonoma/Sequoia 部分键失效**,失效时以系统设置为准,已在对应行标注「需验证」。
5. **Tahoe 26 终端「粘贴保护」**:粘贴含可疑命令会弹确认,属预期行为。

---

## 1. 访达 / Spotlight / 预览 / 桌面 / 调度中心

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| Spotlight 索引状态(搜不到先查这个) | `mdutil -s /`<br>`mdutil -s -a` | 显示各卷索引是否开启/正在建。现有库只有重建 `-E` 与 `-i off`。 | 🟢 | |
| 全局关/开 Spotlight 索引 | `sudo mdutil -a -i off`<br>`sudo mdutil -a -i on` | `-a` 对所有卷;`mds` 长期占 CPU 时先关再按需开。 | 🟡 | |
| 查看某文件的 Spotlight 元数据 | `mdls <path>` | 看到 `kMDItem*` 全部属性(尺寸、时长、来源 URL 等)。 | 🟢 | |
| 手动导入/重建单个文件索引 | `mdimport <path>`<br>`mdimport -L` | 单文件搜不到时强制重导;`-L` 列出所有导入器插件。 | 🟢 | |
| 命令行生成预览/缩略图 | `qlmanage -p <path>`<br>`qlmanage -t -s 512 -o <outdir> <path>` | `-p` 弹预览窗;`-t` 批量出缩略图。 | 🟢 | |
| 修复空白/卡住的快速预览(QuickLook) | `qlmanage -r && qlmanage -r cache && killall Finder` | 重载生成器并清缩略图缓存。 | 🟡 | |
| 递归清理 .DS_Store | `find <dir> -name .DS_Store -type f -delete` | 提交仓库/共享前清干净;误删只影响窗口视图记忆。 | 🟡 | |
| Dock 图标大小 + 悬停放大 | `defaults write com.apple.dock tilesize -int 48`<br>`defaults write com.apple.dock magnification -bool true; killall Dock` | 现有库有自动隐藏/仅显示已开,无尺寸与放大。 | 🟢 | |
| Dock 位置(左/下/右) | `defaults write com.apple.dock orientation -string left; killall Dock` | 取值 `left`/`bottom`/`right`。 | 🟢 | |
| Dock 最小化特效 | `defaults write com.apple.dock mineffect -string scale; killall Dock` | `scale` 比 `genie` 快;还可 `suck`。 | 🟢 | |
| 调度中心不按使用顺序重排空间 | `defaults write com.apple.dock mru-spaces -bool false; killall Dock` | 固定多桌面顺序,避免图标乱跳。 | 🟢 | |
| 加速调度中心动画 | `defaults write com.apple.dock expose-animation-duration -float 0.1; killall Dock` | 进出 Mission Control 更快。 | 🟢 | |
| 设置触发角(Hot Corners) | `defaults write com.apple.dock wvous-br-corner -int 5`<br>`defaults write com.apple.dock wvous-br-modifier -int 0; killall Dock` | 值:2=调度中心 3=应用窗口 4=桌面 5=屏保 10=息屏 11=启动台 12=通知中心 13=锁屏 14=速记;角:tl/tr/bl/br。 | 🟢 | |
| 重置启动台(Launchpad)布局 | `defaults write com.apple.dock ResetLaunchPad -bool true; killall Dock` | 图标排列乱了一键复位。 | 🟢 | Tahoe 26 起启动台改为「应用程序」库,键可能失效(需验证) |
| Finder 默认视图=列表 | `defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"; killall Finder` | 取值 `Nlsv`列表 `icnv`图标 `clmv`分栏 `Flwv`封面流。 | 🟢 | |
| Finder 新窗口默认打开目录 | `defaults write com.apple.finder NewWindowTarget -string "PfHm"; killall Finder` | `PfHm`=个人目录,配 `NewWindowTargetPath` 指定任意路径。 | 🟢 | |
| Finder 排序始终文件夹在前 | `defaults write com.apple.finder _FXSortFoldersFirst -bool true; killall Finder` | 列表/图标视图文件夹置顶。 | 🟢 | |

## 2. 截图 / 录屏(`screencapture` 命令本体)

> 现有库只覆盖 `com.apple.screencapture` 的 `defaults`(保存目录/格式/阴影/文件名),这里补齐 `screencapture` 命令的实拍参数。

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| 交互式框选/选窗口截图存文件 | `screencapture -i ~/Desktop/shot.png` | 空格切换框选/选窗口,Esc 取消。 | 🟢 | |
| 截图直接进剪贴板 | `screencapture -c`<br>`screencapture -i -c` | `-c` 不落盘直接进剪贴板。 | 🟢 | |
| 指定坐标区域截图 | `screencapture -R <x,y,w,h> out.png` | 脚本化固定区域,无需交互。 | 🟢 | |
| 只截某个窗口(可去阴影) | `screencapture -w out.png`<br>`screencapture -w -o out.png` | `-w` 选窗口模式;`-o` 去掉窗口投影。 | 🟢 | |
| 延时截图 | `screencapture -T 5 out.png` | 延时 5 秒,方便摆好界面。 | 🟢 | |
| 整屏含鼠标指针、静音 | `screencapture -C -x out.png` | `-C` 带光标;`-x` 不播快门声。 | 🟢 | |
| 命令行录屏 | `screencapture -v ~/Desktop/rec.mov`<br>`screencapture -v -g rec.mov` | Ctrl-C 结束;`-g` 才录默认麦克风;`-i` 不能与 `-v` 同用。 | 🟡 | Catalina+;首次需「屏幕录制」权限;`-D 2` 指定第 2 块屏 |
| 抓取指定窗口 ID | `screencapture -l<windowid> out.png` | 需先拿到 window id(可用第三方或 CGWindowList)。 | 🟢 | 需验证:获取 windowid 无纯内置命令 |
| 截图输出直接用某 App 打开 | `screencapture -P out.png`<br>`screencapture -B <bundleid> out.png` | `-P` 预览打开;`-B` 指定 App。 | 🟢 | |

## 3. 剪贴板 / 文本

> `pbcopy`/`pbpaste`/`say`/`uuidgen` 基础用法已在现有库,这里补进阶。

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| 文档格式互转(txt/rtf/html/doc/docx) | `textutil -convert html in.txt -output out.html`<br>`textutil -convert txt in.rtf` | 无需开 App 批量转文档格式。 | 🟢 | |
| 剪贴板去格式(保留纯文本) | `pbpaste -Prefer txt \| pbcopy` | 粘贴带样式时清成纯文本。 | 🟢 | |
| 朗读并导出为音频 / 列声音 | `say -o out.aiff "文本"`<br>`say -v '?'` | `-o` 存音频;`-v '?'` 列出可用嗓音。 | 🟢 | |
| 查看剪贴板内容类型 | `osascript -e 'clipboard info'` | 判断当前剪贴板是文本/图片/文件。 | 🟢 | |
| 快速算哈希/编码校验下载 | `shasum -a 256 <file>`<br>`md5 <file>`<br>`base64 -i <file>` | 校验安装包完整性、生成校验值。 | 🟢 | |

## 4. 键鼠 / 快捷键 / 辅助功能

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| 鼠标指针移动速度 | `defaults write NSGlobalDomain com.apple.mouse.scaling -float 3.0` | 值越大越快;`-1` 关加速(直线手感)。 | 🟢 | 注销重登生效 |
| 触控板轻点即点按 | `defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true`<br>`defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1` | 免按压轻触即点。 | 🟢 | 需注销/重启生效 |
| 三指拖移窗口(辅助功能) | `defaults write com.apple.AppleMultitouchTrackpad TrackpadThreeFingerDrag -bool true` | 三指按住拖动窗口/选择。 | 🟢 | 需验证:部分机型键名带 `Trackpad` 前缀差异 |
| 全键盘控制(Tab 遍历所有控件) | `defaults write NSGlobalDomain AppleKeyboardUIMode -int 3` | 对话框可用 Tab 移动到所有按钮。 | 🟢 | |
| 功能键当标准 F1–F12 | `defaults write -g com.apple.keyboard.fnState -bool true` | 无需按 Fn 直接触发 F 键。 | 🟢 | |
| 重置更多类别隐私授权 | `tccutil reset Photos`<br>`tccutil reset AppleEvents`<br>`tccutil reset ListenEvent`<br>`tccutil reset SpeechRecognition`<br>`tccutil reset MediaLibrary` | 现有库列了 Camera/Mic/ScreenCapture/Accessibility/AllFiles,这里补更多服务名(区分大小写)。 | 🟡 | 服务名随版本增减,未知名报错即不支持 |

## 5. 网络(补充)

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| Wi‑Fi 诊断信息(airport 替代) | `sudo wdutil info` | 官方推荐替代 `airport`;可看信道、速率等。 | 🟡 | Sequoia 15+ 会把 BSSID/SSID 打码;需 sudo |
| 【已弃用】airport 扫描附近网络 | `sudo /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -s` | **Sonoma 14.4 已移除**,仅供旧系统参考;新系统用 `wdutil` 或第三方 `macwifi-cli`。 | 🟡 | 14.4+ 命令不存在 |
| 查看当前连接的 Wi‑Fi 名 | `networksetup -getairportnetwork en0` | 现有库无。 | 🟢 | 13/14 有效;**Sequoia 15 起返回空** |
| 开/关 Wi‑Fi 电源 | `networksetup -setairportpower en0 off`<br>`networksetup -setairportpower en0 on` | 命令行断/开无线。 | 🟡 | |
| 连接到指定 Wi‑Fi | `networksetup -setairportnetwork en0 <SSID> <password>` | 脚本化切换网络。 | 🟡 | 密码会出现在命令历史,注意清理 |
| 查看系统 DNS 解析配置 | `scutil --dns` | 看当前生效的 DNS 服务器与搜索域,比 `networksetup` 更全。 | 🟢 | |
| 查看/修改计算机名与主机名 | `scutil --get ComputerName`<br>`sudo scutil --set ComputerName "MacBook"`<br>`sudo scutil --set LocalHostName "MacBook"` | ComputerName(显示名)/LocalHostName(Bonjour)/HostName(命令行)三者可分设。 | 🟡 | |
| Wi‑Fi 硬件与当前连接信息 | `system_profiler SPAirPortDataType` | 看信号/噪声/速率;不含附近网络列表。 | 🟢 | |
| AirDrop 允许通过所有网络接口(含有线) | `defaults write com.apple.NetworkBrowser BrowseAllInterfaces -bool true; killall Finder` | 有线/雷雳网桥场景让 AirDrop 出现。 | 🟢 | |
| 抓包存 pcap 供 Wireshark 分析 | `sudo tcpdump -i en0 -w capture.pcap` | 现有库只有实时打印;`-w` 存文件离线分析。 | 🟡 | 可能含敏感数据 |
| DNS 解析查询(dig/host) | `dig +short apple.com`<br>`host apple.com` | 排查解析问题,比 ping 更直观。 | 🟢 | |
| 查看默认网关 | `route -n get default`<br>`netstat -rn \| grep default` | 快速确认当前出口网关。 | 🟢 | |
| 实时查看各进程网络流量 | `nettop` | 内置交互式流量监视(q 退出)。 | 🟢 | |
| 内置网络测速 | `networkQuality` | Apple 内置带宽/延迟测试;`-v` 详细。 | 🟢 | Monterey 12+ |
| 复位网卡(接口抽风时) | `sudo ifconfig en0 down && sudo ifconfig en0 up` | 比重启省事的软复位。 | 🟡 | |
| 清空 ARP 缓存 | `sudo arp -d -a` | 局域网 IP-MAC 映射异常时清理。 | 🟡 | |

## 6. 磁盘 / 存储(补充)

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| 列出所有磁盘与分区 | `diskutil list` | 看 diskN / 分区 / APFS 容器结构。 | 🟢 | |
| 查看某卷/磁盘详情 | `diskutil info /`<br>`diskutil info disk0` | 文件系统、容量、加密、SMART 状态等。 | 🟢 | |
| 查看 APFS 容器与空间 | `diskutil apfs list` | 看容器内各卷共享空间、快照占用。 | 🟢 | |
| 列出 APFS 卷的快照 | `diskutil apfs listSnapshots /` | 与 `tmutil listlocalsnapshots` 互为佐证。 | 🟢 | |
| 弹出 / 挂载卷 | `diskutil eject /Volumes/X`<br>`diskutil mount disk2s1` | 命令行安全弹出外置盘。 | 🟡 | |
| 检查磁盘 SMART 健康 | `diskutil info disk0 \| grep -i SMART` | 内置 SSD 通常显示 `Verified`。 | 🟢 | |
| 定位大文件(> 指定大小) | `find <dir> -type f -size +500M -exec du -h {} + 2>/dev/null \| sort -rh \| head` | 找出吃空间的巨型文件。 | 🟢 | |
| 创建加密磁盘映像(保险箱) | `hdiutil create -size 1g -encryption -type SPARSE -fs APFS -volname Vault Vault.sparseimage` | 建加密稀疏映像放敏感文件;挂载需密码。 | 🟡 | |
| 【危险】抹掉整块磁盘 | `diskutil eraseDisk APFS NAME /dev/diskN` | **会清空该磁盘全部数据且不可恢复**;务必核对 diskN 是否为目标外置盘,严禁对系统盘执行。 | 🔴 | |
| 【危险】制作 macOS 安装 U 盘 | `sudo /Applications/Install\ macOS\ *.app/Contents/Resources/createinstallmedia --volume /Volumes/USB` | **会抹掉目标 U 盘**;先确认卷名。 | 🔴 | |
| 【危险】dd 写入原始镜像 | `sudo dd if=<img> of=/dev/rdiskN bs=4m` | **写错 of= 会毁盘**;用 `rdiskN`(原始设备)更快;先 `diskutil unmountDisk`。 | 🔴 | |

## 7. 开发者 / 工具链(补充)

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| 模拟器常用管理(simctl) | `xcrun simctl list`<br>`xcrun simctl boot <UDID>`<br>`xcrun simctl openurl booted <url>`<br>`xcrun simctl install booted App.app` | 现有库只有 `delete unavailable`。 | 🟡 | |
| 【危险】抹掉所有模拟器数据 | `xcrun simctl erase all` | **清空全部模拟器内容与设置**,不可恢复。 | 🔴 | |
| 模拟器截图 / 录屏 | `xcrun simctl io booted screenshot shot.png`<br>`xcrun simctl io booted recordVideo rec.mov` | 抓当前启动的模拟器画面。 | 🟢 | |
| 查看/切换 Xcode 命令行工具路径 | `xcode-select -p`<br>`sudo xcode-select -s /Applications/Xcode.app` | 多版本 Xcode 切换编译环境。 | 🟡 | |
| 下载完整系统安装器 | `softwareupdate --fetch-full-installer --full-installer-version 14.5` | 拿到「安装 macOS」App 做 U 盘/重装。 | 🟡 | 需目标版本受支持 |
| 查看编译器版本 | `clang --version`<br>`swift --version` | 确认工具链版本。 | 🟢 | |
| 崩溃地址符号化 | `atos -o <Binary> -arch arm64 -l <loadAddr> <addr>` | 把 crash 里的地址还原成函数/行号。 | 🟢 | Apple Silicon 用 `-arch arm64`,Intel 用 `x86_64` |
| 校验 / 转换 plist | `plutil -lint x.plist`<br>`plutil -convert xml1 x.plist`<br>`plutil -convert binary1 x.plist` | 语法检查与 XML/二进制互转。 | 🟢 | |
| 定位命令来源 | `which -a python3`<br>`type brew`<br>`command -v node` | 排查 PATH 里到底用的是哪个可执行。 | 🟢 | |
| Python 建虚拟环境(内置) | `python3 -m venv .venv && source .venv/bin/activate` | 无需第三方即可隔离依赖。 | 🟢 | |
| git:撤销工作区改动 | `git restore <path>`<br>`git restore --staged <path>` | 丢弃未提交修改 / 取消暂存。 | 🟡 | 撤销后未提交内容不可恢复 |
| git:改最后一次提交 / 找回丢失提交 | `git commit --amend`<br>`git reflog` | `reflog` 是「后悔药」,能找回被 reset 的提交。 | 🟢 | |
| 【危险】git 强制清空到干净状态 | `git reset --hard && git clean -fd` | **删除所有未提交改动与未跟踪文件**,不可恢复。 | 🔴 | |

## 8. 系统维护

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| 重建字体缓存 | `sudo atsutil databases -remove`<br>`atsutil server -shutdown && atsutil server -ping` | 字体显示异常/重复时重建;之后重启更稳妥。 | 🟡 | |
| 重启声音服务(没声音/输出卡住) | `sudo killall coreaudiod` | 音频子系统抽风时软复位。 | 🟡 | |
| 重启蓝牙服务(设备连不上) | `sudo pkill bluetoothd` | 守护进程会自动拉起;比关开蓝牙彻底。 | 🟡 | |
| 【危险】重启窗口服务器(界面全卡死) | `sudo killall -HUP WindowServer` | **会强制注销当前用户、丢失未存内容**;仅在界面完全卡死时用。 | 🔴 | |
| 手动跑系统维护脚本 | `sudo periodic daily weekly monthly` | 轮转日志、清临时文件等;平时由系统自动执行。 | 🟡 | |
| 查看 / 清空 NVRAM 变量 | `nvram -p`<br>`sudo nvram -c` | 看/清启动相关变量。 | 🟡 | Apple Silicon 无「PRAM/SMC 重置」组合键概念,清空后个别设置回默认 |
| 同步系统时间 | `sudo sntp -sS time.apple.com` | 时间跑偏导致证书/登录异常时强制校时。 | 🟡 | |
| 进恢复模式 / 安全模式(说明,非命令) | `# Apple Silicon: 关机后长按电源键→选项`<br>`# Intel: 开机按住 ⌘R;安全模式按住 Shift` | 无对应终端命令,做成图文引导更合适。 | 🟢 | AS 与 Intel 进入方式不同 |

## 9. 电池 / 电源(补充)

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| 电池循环次数(ioreg) | `ioreg -r -c AppleSmartBattery \| grep -i cycle` | 现有库用 `system_profiler`,`ioreg` 更快更细。 | 🟢 | |
| 电池设计容量 vs 当前容量 | `ioreg -r -c AppleSmartBattery \| grep -iE "DesignCapacity\|MaxCapacity\|AppleRawMaxCapacity"` | 估算电池健康度(当前/设计)。 | 🟢 | |
| 低电量模式开关 | `sudo pmset -a lowpowermode 1`<br>`sudo pmset -a lowpowermode 0` | 命令行开/关低电量模式。 | 🟡 | |
| 谁在阻止睡眠 / 唤醒记录 | `pmset -g assertions`<br>`pmset -g log \| grep -i "wake\|sleep"` | 排查「合盖不睡」「半夜自己醒」。 | 🟢 | |
| 立即息屏 / 立即睡眠 | `pmset displaysleepnow`<br>`pmset sleepnow` | 一键锁屏息屏 / 直接进睡眠。 | 🟢 | |
| 定时唤醒/开机 | `sudo pmset repeat wakeorpoweron MTWRF 08:00:00` | 工作日定时唤醒;`pmset repeat cancel` 取消。 | 🟡 | |
| 【危险】合盖不睡眠(外接屏常用) | `sudo pmset -c disablesleep 1` | 接电源合盖继续运行;**散热差时有过热风险**,用完 `disablesleep 0`。 | 🔴 | |

## 10. 安全 / 隐私(补充)

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| 开启 / 关闭 FileVault | `sudo fdesetup enable`<br>`sudo fdesetup disable` | 现有库只有 `status`。启用会生成恢复密钥,务必保存。 | 🟡 | 关闭需全盘解密,耗时 |
| 查看已授权解锁的用户 | `sudo fdesetup list` | 看谁能在开机时解锁 FileVault。 | 🟢 | |
| 应用防火墙状态/加放行 | `/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate`<br>`sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /Applications/App.app` | 现有库用 `alf` defaults + stealth,这里用官方 CLI 查看/加应用。 | 🟡 | |
| 评估某文件能否通过 Gatekeeper | `spctl --assess -vv /path/App.app` | 分发前自查是否会被拦。 | 🟢 | |
| 钥匙串:读取已存密码 | `security find-generic-password -s "服务名" -w`<br>`security find-internet-password -s host -w` | **会明文打印密码**,注意肩窥/日志。 | 🟡 | |
| 钥匙串:解锁 / 锁定 / 列出 | `security unlock-keychain ~/Library/Keychains/login.keychain-db`<br>`security lock-keychain`<br>`security list-keychains` | 脚本访问钥匙串前先解锁。 | 🟡 | |
| 钥匙串:写入一条密码 | `security add-generic-password -a <账户> -s <服务> -w <密码>` | 脚本化存凭据(会进命令历史)。 | 🟡 | |
| 【危险】向系统钥匙串添加受信根证书 | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain cert.cer` | **全局信任该证书**,可被用于中间人;仅装可信 CA。 | 🔴 | |
| 校验下载文件哈希是否匹配 | `echo "<期望sha256>  <file>" \| shasum -a 256 -c` | 输出 `OK` 才算完整未被篡改。 | 🟢 | |
| 打开某 App 的沙盒容器目录 | `open ~/Library/Containers/<bundleid>/Data` | 排查沙盒 App 的数据/配置。 | 🟢 | |

## 11. 显示 / 音频

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| 设置 / 读取 / 静音 系统音量 | `osascript -e 'set volume output volume 50'`<br>`osascript -e 'set volume with output muted'`<br>`osascript -e 'output volume of (get volume settings)'` | 0–100;比按键更精确,可脚本化。 | 🟢 | |
| 切换深色 / 浅色模式 | `osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to not dark mode'` | 一键切换外观。 | 🟢 | |
| 设置桌面壁纸 | `osascript -e 'tell app "Finder" to set desktop picture to POSIX file "/path.jpg"'` | 脚本换壁纸。 | 🟢 | 多显示器/多空间可能只改当前 |
| 内置无官方亮度/Night Shift CLI(说明) | `# 亮度:m1ddc/brightness(第三方)`<br>`# Night Shift:无稳定内置命令` | 系统未提供稳定的亮度/夜览命令行,见第三方工具区。 | 🟢 | 内置显示亮度可用私有框架,不稳定 |

## 12. 进程 / 性能(补充)

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| ps 按 CPU / 内存排序找大户 | `ps aux \| sort -nrk 3 \| head`<br>`ps aux \| sort -nrk 4 \| head` | 现有库只有 `top`;`ps` 适合抓单次快照。 | 🟢 | |
| top 单次快照(不进交互界面) | `top -l 1 -o cpu -n 15` | 脚本里取一次性数据。 | 🟢 | |
| 采样某进程的调用栈 | `sample <pid> 5 -file out.txt` | 采样 5 秒,分析卡顿/高 CPU;自己的进程无需 sudo。 | 🟢 | |
| 卡死进程取堆栈(spindump) | `sudo spindump <pid> 5 -o out.txt` | 采无响应进程的完整调用栈。 | 🟡 | |
| 能耗/CPU/GPU 功耗观测 | `sudo powermetrics --samplers cpu_power,gpu_power -i 1000 -n 5` | 定位耗电大户;Apple Silicon 数据尤其丰富。 | 🟡 | 需 sudo |
| 查看某进程打开的文件/端口 | `lsof -p <pid>` | 排查句柄泄漏、占用文件。 | 🟢 | |
| 文件系统调用实时跟踪 | `sudo fs_usage -w -f filesystem <进程名>` | 看某进程在读写哪些文件。 | 🟡 | 受 SIP 限制,系统进程可能看不全 |
| 磁盘 I/O 速率 | `iostat -w 1` | 每秒刷新磁盘吞吐。 | 🟢 | |
| 调整进程优先级 | `renice +10 -p <pid>`<br>`nice -n 10 <cmd>` | 给后台任务降优先级,少抢 CPU。 | 🟡 | 降到负值需 sudo |
| 查看/临时提升打开文件数上限 | `ulimit -n`<br>`ulimit -n 4096` | 开发时 `too many open files` 应急。 | 🟢 | 仅当前 shell 生效 |

## 13. 应用管理 / 登录项

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| 列出当前登录项 | `osascript -e 'tell app "System Events" to get the name of every login item'` | 看开机自启的 App(与 LaunchAgents 互补)。 | 🟢 | |
| 添加 / 删除登录项 | `osascript -e 'tell app "System Events" to make login item at end with properties {path:"/Applications/X.app", hidden:false}'`<br>`osascript -e 'tell app "System Events" to delete login item "X"'` | 命令行增删自启项。 | 🟡 | Ventura+ 现代 App 多用 SMAppService,可能不显示于此 |
| 打印某 launchd 服务详情 | `launchctl print gui/$(id -u)/<label>` | 现有库有 list/bootout/bootstrap/disable;`print` 看单项状态、退出码。 | 🟢 | |
| 立即重启某 launchd 服务 | `launchctl kickstart -k gui/$(id -u)/<label>` | `-k` 先杀再拉起,调试常驻服务用。 | 🟡 | |
| 列出已装系统扩展 | `systemextensionsctl list` | 看第三方网络/驱动扩展(VPN、杀软等)。 | 🟢 | 卸载/重置需开发者模式 |

## 14. 其它高频 / 隐藏 defaults

| 标题 | 命令 | 说明 | 风险 | 版本/芯片 |
| --- | --- | --- | --- | --- |
| 读取 / 备份 / 还原某域设置 | `defaults read com.apple.dock`<br>`defaults export com.apple.dock ~/dock.plist`<br>`defaults import com.apple.dock ~/dock.plist` | 改 defaults 前先导出备份,随时还原。 | 🟢 | |
| 删除某个 defaults 键(还原默认) | `defaults delete com.apple.dock <key>; killall Dock` | 任何 `defaults write` 都可这样撤销,恢复系统默认。 | 🟡 | |
| 列出所有可用 defaults 域 | `defaults domains \| tr ',' '\n'` | 探索有哪些 App/系统域可调。 | 🟢 | |
| 菜单栏时钟显示秒 | `defaults write com.apple.menuextra.clock ShowSeconds -bool true; killall SystemUIServer` | 需要秒级时间时用。 | 🟢 | Sonoma/Sequoia 时钟归控制中心,可能需 `killall ControlCenter`(需验证) |
| 菜单栏显示电量百分比 | `defaults write com.apple.controlcenter BatteryShowPercentage -bool true; killall ControlCenter` | 一键显示电量数字。 | 🟢 | Big Sur–Ventura 有效;Sonoma+ 建议用系统设置(需验证) |
| 关闭崩溃报告弹窗 | `defaults write com.apple.CrashReporter DialogType none` | App 崩溃不再弹「重新打开」对话框;改回 `crashreport`/`developer`。 | 🟡 | |
| 关闭「打开应用要不要确认」的抖动/其它 | `defaults write com.apple.LaunchServices LSQuarantine -bool false`(已在现有库,勿重复) | ——(占位提醒:此键现有库已有,勿重复收录) | — | 重复,见现有库 |

> 说明:上表最后一行仅作为**去重提醒**,不计入新增条目。

---

## 第三方工具清单(需自行安装,均非 Apple 官方)

> 建议 App 内检测到已安装才展示对应功能;安装命令多为 Homebrew。许可证以官方仓库为准,下列为概况。

| 工具 | 用途 | 安装 | 许可证(概况) | 备注 |
| --- | --- | --- | --- | --- |
| `mas` | Mac App Store 命令行(列出/升级/安装)`mas list` `mas upgrade` `mas install <id>` | `brew install mas` | MIT | 新系统需已登录 App Store;历史上登录/购买子命令时有失效 |
| `displayplacer` | 保存/恢复多显示器分辨率与排列 `displayplacer list` | `brew install displayplacer` | MIT | 内置无等价命令 |
| `ncdu` | 终端交互式磁盘占用分析 | `brew install ncdu` | MIT/BSD 类 | 比 `du` 直观,快速找大目录 |
| `nvm` / `fnm` | Node 版本切换 | `brew install fnm` 或 nvm 脚本 | fnm: GPL-3.0;nvm: MIT | 切换 Node,配合 `.nvmrc`/`.node-version` |
| `pyenv` | Python 多版本管理 | `brew install pyenv` | MIT | 隔离系统 Python;配 `pyenv-virtualenv` |
| `macwifi-cli` | `airport -s` 替代,扫描附近 Wi‑Fi/读密码 | `brew install jaisonerick/tap/macwifi-cli` | 见仓库 | 首次扫描弹定位授权;仅 Apple Silicon macOS 13+ |
| `blueutil` | 命令行开关/查询蓝牙、连设备 | `brew install blueutil` | BSD 类 | 比 `pkill bluetoothd` 精细 |
| `m1ddc` | Apple Silicon 经 DDC/CI 调外接显示器亮度/对比 | `brew install m1ddc` | MIT | 仅外接显示器;内置屏不适用 |
| `brightness` | 读/写内置显示亮度 | `brew install brightness` | MIT | 新系统私有接口可能失效(需验证) |
| `switchaudio-osx` | 命令行切换音频输入/输出设备 | `brew install switchaudio-osx` | GPL/MIT 类 | `SwitchAudioSource -a` 列设备 |
| `mtr` | 融合 ping+traceroute 的实时链路诊断 | `brew install mtr` | GPL-2.0 | 需 sudo |
| `htop` / `btop` | 彩色交互式进程/资源监视 | `brew install btop` | htop: GPL;btop: Apache-2.0 | 比 `top` 好用 |
| `duti` | 命令行设置文件类型默认打开方式 | `brew install duti` | 公共领域/宽松 | 批量改「用某 App 打开该类型」 |
| `tag` | 命令行读写 Finder 标签 | `brew install tag` | MIT | 配合 `mdfind` 按标签检索 |
| `terminal-notifier` | 脚本里发系统通知 | `brew install terminal-notifier` | MIT | 长任务完成提醒 |
| `trash` | 删除到废纸篓而非 `rm` 直删(可找回) | `brew install trash` | MIT | 比 `rm -rf` 安全 |

---

## 建议新增的功能页 / 交互点

1. **Wi‑Fi 诊断卡片**:整合 `networkQuality`(测速)+ `scutil --dns`(当前 DNS)+ 当前 SSID;并在页面显著说明「附近网络扫描因 Apple 限制需第三方/授权」,避免用户以为 App 坏了。
2. **截图/录屏工作台**:把 `screencapture` 的区域/窗口/延时/进剪贴板/录屏做成一排按钮 + 保存目录/格式选择器(复用现有 `com.apple.screencapture` defaults),录屏前检测「屏幕录制」权限。
3. **磁盘瘦身向导**:`diskutil list`/`apfs list` 可视化 + 「找大文件」(find size)+ 本地快照回收(现有 tmutil)+ 各类缓存清理,勾选后显示「预计释放」。
4. **界面微调开关面板**:把第 1、14 组的 `defaults`(Dock 尺寸/位置/放大、触发角、Finder 视图、时钟秒、电量百分比、功能键)做成 Toggle;每个 Toggle 底层配一次 `defaults delete` 作「一键还原」。
5. **电池健康仪表盘**:`ioreg` 循环次数 + 设计/当前容量算健康度 + 低电量模式开关 + `pmset -g assertions`(谁在阻止睡眠)。
6. **进程/性能体检**:`ps` 排序 Top、`powermetrics` 能耗榜、`lsof -p` 查占用;发现异常给「结束进程」按钮。
7. **登录项 & 后台项管理器**:合并 login items(osascript)、LaunchAgents/Daemons(现有 launchctl)、`systemextensionsctl list`,列表 + 启停开关。
8. **钥匙串 & FileVault 小工具**:FileVault 开关/恢复密钥提示、防火墙放行应用;涉及明文密码的 `security find-*password` 需二次确认并遮罩。
9. **开发者面板**:simctl 常用动作、Xcode 路径切换、`atos` 符号化、`plutil -lint`,以及现有清缓存,面向进阶用户。
10. **「一键还原默认」总开关**:凡本 App 改过的 `defaults`,统一 `defaults export` 备份并提供批量 `defaults delete` 回滚,消除用户对「改坏了怎么办」的顾虑。

---

## 与现有 135 条的重叠 / 替换建议

**明确重叠(本清单已剔除,不重复收录)**:`codesign`/`spctl`/`xattr` 全家、`hdiutil attach/detach`、`installer`/`pkgutil`、Rosetta/`arch`/`lipo`、`tccutil reset`(基础几项)、`csrutil`、`diskutil verify/repair/resetUserPermissions`、`chown/chmod/chflags`、`df/du`、`mdutil -E`/`mdfind`、DNS 刷新、`lsof` 端口查杀、`networksetup` 代理/DNS、`tcpdump` 实时、`defaults` 截图目录/格式/隐藏文件/扩展名/Dock 自动隐藏/键盘重复、`otool`/`install_name_tool`/`ldid`/`insert_dylib`、`caffeinate`、`pmset -g`、`top/vm_stat/memory_pressure`、`tmutil` 快照、`launchctl` 基础、`softwareupdate -l/-ia`、`sips`/`iconutil`、`brew` 修复、`fdesetup status`、`socketfilterfw` stealth 等。

**增强 / 替换建议(对现有条目给更好版本,建议原地升级而非新增)**:

- **电池健康**:现有用 `system_profiler SPPowerDataType`,建议**替换/并列** `ioreg -r -c AppleSmartBattery | grep -i cycle`(更快)并补「设计容量 vs 当前容量」算健康度。
- **Wi‑Fi 相关**:现有网络组无 Wi‑Fi 专项;若未来加,务必**直接采用本清单的版本注记**(`airport` 已移除、`wdutil` 打码、`getairportnetwork` 15 失效),否则会给出过时命令。
- **`screencapture`**:现有只有 `defaults`(设置),建议把 `screencapture` 命令本体(录屏/区域/剪贴板)**作为新功能补上**,两者互补。
- **`spctl --master-disable`**:现有条目正确标了新系统行为;可**并列** `spctl --assess -vv` 作为「分发前自检」的安全只读版。
- **登录项**:现有仅 `launchctl`;建议**并列** osascript login items 与 `systemextensionsctl list`,覆盖现代 App 的自启方式。
- **可逆性说明**:现有 `defaults` 条目建议统一追加一句「撤销:`defaults delete <domain> <key>`」,与本清单第 14 组一致,降低用户心理负担。

---

### 附:命名与落库对齐

本清单每条已含 **分类 / 标题(症状式)/ 命令(占位符)/ 说明 / 风险 / 版本或芯片注意**,可直接映射到 `CommandEntry(category,title,command,detail,risk,versionNote)`。危险与不可逆项(抹盘、`dd`、`git reset --hard`、`killall WindowServer`、加信任根证书、`disablesleep`)均已 🔴 显著标注,建议入库后在 UI 强制二次确认。标「需验证」的少数 `defaults` 键(控制中心域、三指拖移键名、启动台重置)建议在目标系统实测后再上线。
