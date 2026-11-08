# 秋绪 ArkUI 历史基线公开快照

这是秋绪 HarmonyOS ArkUI 客户端的一份源码快照，版本标识为
`2.3.4 / 2003004`。


## 保留内容

- ArkUI 页面、主题、路由和基础播放器封装
- Kazumi 兼容规则的数据模型与解析器
- 搜索、详情、历史、收藏、下载、弹幕和设置等基础客户端代码
- HarmonyOS 构建配置、C++ 桥接源码及公开资源


## 构建说明

需要自行安装 DevEco Studio、HarmonyOS SDK，并配置自己的签名材料。
本仓库不提供签名配置，也不包含构建所需的预编译 `libmpv` 二进制。

```powershell
$env:DEVECO_SDK_HOME='<HarmonyOS SDK 路径>'
$env:JAVA_HOME='<DevEco Studio JBR 路径>'
node '<DevEco Studio>/tools/hvigor/bin/hvigorw.js' --mode module -p product=default assembleHap --no-daemon
```

## 许可证与来源

本项目按 GNU GPL v3 发布，详见 [LICENSE](LICENSE) 和
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

客户端能力受 Kazumi 项目启发，部分历史实现从 Kazumi 或其 HarmonyOS 分支移植：

- https://github.com/ErBWs/Kazumi
- https://github.com/Predidit/Kazumi

KazumiRules 规则仓库按 MIT License 发布：

- https://github.com/Predidit/KazumiRules

## 发布边界

本快照用于历史代码审阅、许可证归档和开发交流，不代表秋绪当前版本，
不应被表述为任何现行安装包的完整 Corresponding Source。
