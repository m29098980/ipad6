# MicProbe —— iPad 麦克风采集探针

一个最小可用的 iPadOS App，用来验证「麦克风 → 16 kHz 重采样 → 512 样本分帧 → 电平/上传」这条链路。
跑通之后再接入唤醒词引擎（Porcupine 等）。

**全程不需要 Mac。** 编译交给 GitHub Actions 的 macOS 运行器，签名和安装交给 Windows 上的 Sideloadly。

---

## 先决条件

| 项目 | 要求 |
|---|---|
| iPad | iPad 6 代（A1893/A1954），**已升级到 iPadOS 17.x** |
| Apple ID | 普通免费 ID 即可，不用付费开发者账号 |
| GitHub 账号 | 免费账号即可（公开仓库的 macOS 构建分钟数无限） |
| Windows 工具 | iTunes（**网页版**，不要 Microsoft Store 版）、Sideloadly |
| 数据线 | Lightning 数据线（能传数据，不是只能充电的） |

---

## 步骤 A：把工程推到 GitHub

在 Git Bash 里执行（把 `<你的用户名>` 换成自己的）：

```bash
cd "C:/Users/JYChan/WorkBuddy/2026-10-31-17-10-43/MicProbe"
git init -b main
git add .
git commit -m "init micprobe"
```

先去 https://github.com/new 建一个仓库，名字随意（例如 `micprobe`），**选 Public**，不要勾选任何初始化文件。

然后把本地仓库推上去：

```bash
git remote add origin https://github.com/<你的用户名>/micprobe.git
git push -u origin main
```

> 仓库必须是 Public。私有仓库每月只有约 200 分钟的 macOS 构建额度，虽然也够用十几次，但公开仓库是无限免费的。

---

## 步骤 B：让 GitHub 编译出 ipa

推送完成后，打开仓库页面 → 顶部 **Actions** 标签 → 左侧 **build-ipa** → 右侧 **Run workflow** 按钮（推送时其实已经自动触发了一次，可以先看那次的结果）。

等大约 4–6 分钟，进那次运行，最下面 **Artifacts** 里会有 `MicProbe-ipa`，下载下来是个 zip，解压得到 `MicProbe.ipa`。

如果构建失败了，点开 **编译（不签名）** 那一步看 `xcodebuild` 的报错，日志里会有具体的文件名和行号。

---

## 步骤 C：装到 iPad

1. **Windows 上准备环境**
   - 装 iTunes：从 apple.com 下 **64 位网页版安装包**。如果你的系统里已经装了 Microsoft Store 版本的 iTunes，先卸载，两个版本会打架。
   - 装 Sideloadly：https://sideloadly.io ，当前版本 v0.70.1。
   - 装完重启一次电脑（让 Apple 的驱动生效）。

2. **iPad 上开开发者模式**
   - 设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启 → 重启后再确认一次。
   - 这个开关**只有在设备连过一次电脑之后才会出现**。第一次找不到是正常的。

3. **USB 连接并信任**
   - 用数据线把 iPad 接到这台 Windows。
   - iPad 弹「要信任此电脑吗」→ 点信任 → 输入锁屏密码。

4. **Sideloadly 签名安装**
   - 打开 Sideloadly，把 `MicProbe.ipa` 拖进去。
   - `Apple ID` 填你的普通 Apple ID（会走双重认证，可能需要你输入验证码）。
   - 点 `Start`，等它跑完 unpack → sign → install。
   - 成功后 iPad 桌面上出现 **MicProbe**。

5. **信任企业级开发者证书**
   - 第一次点开 App 可能会提示「不受信任的开发者」。
   - 去 设置 → 通用 → VPN 与设备管理 → 找到你的 Apple ID → 点「信任」。

6. **打开 App → 点「开始采集」→ 允许麦克风权限**

---

## 步骤 D：验证什么

跑起来之后，逐项确认：

- [ ] 状态灯变红，文字显示「监听中」
- [ ] 对着麦克风说话，绿色电平条跟着动，dBFS 数值在 -50 ~ -10 之间跳
- [ ] 帧计数持续增长，时长按秒走
- [ ] 日志里显示「硬件格式 48000 Hz / 1 ch → 目标 16000 Hz / 1 ch」（数字可能是 44100，取决于设备）
- [ ] 手指碰一下屏幕，屏幕不会自己灭

只要这五条都过，音频链路就是通的，可以接唤醒词了。

---

## 后续：接入 Porcupine

代码里留好了位置。要改三个地方：

1. **project.yml** 里加依赖：

   ```yaml
   packages:
     Porcupine:
       url: https://github.com/Picovoice/porcupine.git
       from: 3.0.0
   ```

   然后在 target 下加 `dependencies: - package: Porcupine`。

2. **AccessKey 不能进公开仓库。** 在 GitHub 仓库 Settings → Secrets and variables → Actions 里加一个 `PORCUPINE_KEY`，然后在 workflow 的编译步骤前加一步生成 `Sources/Secrets.swift`：

   ```yaml
   - name: 注入 AccessKey
     run: echo "enum Secrets { static let porcupineKey = \"${{ secrets.PORCUPINE_KEY }}\" }" > Sources/Secrets.swift
   ```

   同时把 `Secrets.swift` 加进 `.gitignore`。

3. **AudioEngine.handleFrame** 里，每帧传给 Porcupine 并判断返回值。帧长已经是 512，正好是 Porcupine 的 `frameLength`，不需要再改切帧逻辑。

> Porcupine 是二进制 xcframework。GitHub Actions 用的是完整 Xcode 环境，能正常链接；Sideloadly 重签时也会遍历 `Frameworks/` 目录重新签名。这一步建议单独试一次，确认能装能启动，再往下做。

---

## 已知问题

**重采样器创建失败** — iPad 上如果接了蓝牙耳机，输入采样率可能被切到 8 kHz 或 16 kHz，且声道数变化。当前代码每次启动都重新读硬件格式，所以启动前切换设备后重新点一次「开始采集」即可。

**装完点开闪退** — 九成是签名过期（免费 ID 只有 7 天）。Sideloadly 自带后台守护进程会自动重签，但需要它保持运行。

**Sideloadly 报 `Provision failed`** — 检查 Apple ID 是否开了双重认证、iTunes 是否是网页版、iPad 是否已信任这台电脑。

**构建报 `No such module 'Porcupine'`** — 说明 SPM 依赖没解析成功。在 workflow 里加一步 `xcodebuild -resolvePackageDependencies` 再编译。

---

## 文件结构

```
MicProbe/
├── project.yml                  # XcodeGen 工程定义（.xcodeproj 由它生成，不入库）
├── Sources/
│   ├── MicProbeApp.swift        # App 入口，前台常亮
│   ├── ContentView.swift        # 界面：状态 / 电平条 / 帧计数 / 日志
│   ├── AudioEngine.swift        # 采集 + 重采样 + 分帧 + 电平
│   ├── Uplink.swift             # 可选：原始 PCM 上传
│   └── Config.swift             # 采样率、帧长、上传地址
├── Support/Info.plist           # 由 XcodeGen 生成（不入库）
└── .github/workflows/build.yml  # 云端编译流水线
```
