# Peakmon

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple)](https://github.com/crafcat7/Peakmon/releases)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

[English](README.md) · [简体中文](README.zh-CN.md)

Peakmon 是一个原生 macOS 菜单栏系统监视器，用于在菜单栏和仪表盘窗口中查看常用系统指标。

它目前支持 CPU、GPU、内存、电池、磁盘、网络和进程等实时指标。项目使用 SwiftUI 和本地 Swift packages 构建，无 Electron 外壳，无遥测上报，数据仅在本机采集和展示。

<p align="center">
  <img alt="菜单栏（浅色）" src="Docs/assets/Run-Light.png" width="280" />
  &nbsp;&nbsp;
  <img alt="菜单栏（深色）" src="Docs/assets/Run-Dark.png" width="280" />
</p>

<p align="center">
  <img alt="仪表盘（浅色）" src="Docs/assets/Dashboard-Light.png" width="640" />
</p>

<p align="center">
  <img alt="仪表盘（深色）" src="Docs/assets/Dashboard-Dark.png" width="640" />
</p>

## 下载

**[下载最新版本](https://github.com/crafcat7/Peakmon/releases/latest)**

下载最新 `Peakmon.app.zip`，解压后拖到 `/Applications`。首次启动右键 → 打开放行。

### Homebrew

```sh
brew install crafcat7/cellar/peakmon
```

## 功能

**菜单栏** — 紧凑的 segment 布局（CPU%、内存压力、网速、GPU 利用率等），栅格化为单张图片。文字颜色自动适配菜单栏背景（深色/浅色/全屏）。

**弹窗** — 点击菜单栏图标查看 sparkline 图表、每项指标的详细数据、高占用进程列表。

**仪表盘** — 统一窗口，包含 CPU、Memory、GPU、Power、Disk、Network 等卡片。每张卡有大数字、sparkline 图表和展开详情。支持全局快捷键 `⌃⌥⌘D`。

**帧率** — 位于历史之后的独立页面，用于进行 60 秒桌面或单应用观察。支持开始、停止、添加标记和查看已记录的趋势。切页或隐藏窗口后继续采集；结果保留至更改目标或开始新观察。

**自定义** — 独立开关菜单栏与弹窗，开关或拖拽排序仪表盘卡片，自定义配色，并选择菜单栏显示哪些指标。

## 数据来源

所有数据保留在本地，无网络请求。

| 指标 | 来源 |
|------|------|
| CPU / 内存 | `host_statistics64` (Darwin) |
| GPU 利用率 | IOAccelerator `PerformanceStatistics` (IOKit) |
| 桌面帧率 | IOReport 显示协处理器 `swap` 计数器（Apple Silicon，取决于系统是否提供） |
| 应用帧率 | macOS 27+ `metalperftrace` 聚合 Metal 呈现统计 |
| 功耗（分轨） | IOReport "Energy Model" (libIOReport, dlopen) |
| 温度 | SMC keys `Tp0X` / `Tg0D` |
| 风扇转速 | SMC key `F0Ac` |
| 电池 | IOKit `AppleSmartBattery` |
| 磁盘 | IOKit `IOBlockStorageDriver` |
| 网络 | `getifaddrs` (Darwin) |
| 进程 | `proc_pidinfo` (libproc) |

**桌面观察** 为一次观察固定一个可用显示计数器，优先选择内建显示器；只有外接显示器时，需要显示活动来识别来源。不会把多个显示器的帧数相加。该读数反映桌面呈现活动，与屏幕配置刷新率不同；显示配置变化会结束观察。

**应用观察** 需要 macOS 27 或更高版本，以及可读取的 Metal 呈现来源。通过进程实例识别所选应用及可归属的辅助进程；存在多个图层时，需要选择一个来源。数据保留原始记录窗口，可能延迟数秒到达。可选帧间隔来自实测的平均上屏间隔，不从 FPS 推算。不支持的应用或缺测显示不可用状态，不记作零值，也不修改 HUD 或逐帧追踪设置。当前观察结果保存在内存中，与历史页面独立。

## 系统要求

- macOS **14.0** Sonoma 或更高
- 推荐 Apple Silicon；Intel 尽力支持

## 从源码构建

```sh
git clone https://github.com/crafcat7/Peakmon.git
cd Peakmon
./Tools/release.sh
```

或用 Xcode 打开 `Peakmon.xcodeproj` 直接 Run。

测试：

```sh
swift test --package-path Packages/PeakmonCore
```

## 仓库结构

```
Peakmon/                   # 应用主体（菜单栏 + 仪表盘 + 历史 + 帧率 + 设置）
Packages/
  PeakmonCore/             # MetricKind, MetricsStore, MetricsScheduler, SMC/IOReport 桥
  PeakmonCollectors/       # 系统指标与桌面/Metal 帧率采集器
  PeakmonUI/               # 共享视图（sparkline, card 模板, DashboardComponents）
```

## 许可证

[Apache License 2.0](LICENSE)
