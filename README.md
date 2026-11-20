# 河畔小镇闯关助手

Windows 桌面助手，通过《河畔小镇》（River Towns）的内部接口读取实时棋盘和拼块。助手选择合法落点、摆放建筑、等待游戏写入成绩，并按游戏的解锁规则继续选关。

## 启动

1. 在 Steam 中安装《河畔小镇》。
2. 双击 `Start.cmd`，点击 **启动闯关**。程序会查找 Steam 库。也可以用 `Start.cmd -GamePath "游戏安装目录"` 指定位置。
3. 在助手窗口查看关卡、当前分数、三星门槛和剩余拼块。可点击 **暂停** 或 **继续**。

第一次运行需要约 1.1 GB 空间来准备本地游戏副本。程序使用 UE4SS v4.0.0。如果自动下载失败，将官方发行包 `UE4SS_v4.0.0.zip` 放到 `.river-runtime` 后重试。[UE4SS 官方发行页](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0)

## 进度和日志

本地副本以本地模式运行，存档位于 `.river-runtime/profile`。重新启动时会从第一世界的选关页面读取这份存档。每次启动的状态和动作日志保存在 `.river-runtime/run-*/status.tsv` 和 `.river-runtime/run-*/events.tsv`。

助手读取已放建筑、障碍和待放拼块，用游戏的计分预览比较当前落点，并根据关卡向后搜索。搜索兼顾同色连片、跨河连接、树木复苏、遗迹修复和腐化围堵，并给后续拼块留下可用空间。每次实际落子都由游戏校验。

助手会自动跳过存档中已有三星的关卡，优先补刷当前世界的低星关卡，再挑战尚未通关的关卡。窗口会显示本次选关是补星、挑战新关还是重试。某关首次结算低于三星会换一套摆法尝试一次，成绩由游戏按最高分保存。世界门缺星时会继续补分，达到重试上限后暂停并显示原因。

## 全三星闯关

`Start.cmd -Campaign` 静音运行全三星模式。助手按世界顺序跳过已满星的关卡，直到当前世界的内置关卡全部三星才会过门。首局低于三星会重试同一关。连续两局低于三星会保存结算记录、退出游戏，等待复盘更新。关卡、计数和待复盘状态保存在 `.river-runtime/campaign/state.json`。

`Start.cmd -Campaign -SteamSave -Visible` 从 Steam 安装版使用的本地正式存档续打，并显示独立的静音游戏窗口。启动前请退出正在运行的游戏。闯关状态保存在 `.river-runtime/campaign-steam/state.json`。复盘后可加上 `-Resume` 继续，或用 `Start.cmd -StopCampaign -SteamSave` 停止。

`Start.cmd -StopCampaign` 停止助手存档的闯关或试跑，可用 `Start.cmd -Campaign -Resume` 恢复。需要在隔离存档中验证某关时，可用 `Start.cmd -Trial 02/LVL04_Geyser`。取得三星后，用 `Start.cmd -Campaign -ReviewedRun run-…` 传入对应的试跑编号，回到助手存档重打同一关。

在 Steam 构建 `18195330` 上，已从本地正式存档实机续打并核验四个世界共 40 关三星。高难关卡可在两局结算后根据日志调整策略，再继续挑战同一关。游戏更新后，内部函数名或数据结构可能变化。

## 验证

`Start.cmd -Verify` 使用静音的独立测试存档启动助手，检查自动摆放、结算和连续选关。

`powershell -ExecutionPolicy Bypass -File tests\Campaign.Tests.ps1` 检查结算计数、检查点和复盘续跑条件。
