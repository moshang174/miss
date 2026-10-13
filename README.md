# 怀念 (huainian)

一款虚拟人物情感陪伴对话软件。导入真实聊天记录即可"克隆"Ta 的说话方式，
拥有长期记忆，会主动给你发消息。UI 为 QQ 聊天风格。
（前身为"异次元通讯"，V6.0 重构后更名）

## V7.0 架构说明

- **对话底座**：云端大模型 API（OpenAI 兼容协议，`/chat/completions`）。
  - **免费通道（出厂默认）**：公共免费端点，无需密钥开箱即用；
    内置 POST/GET 双通道 × 3 轮退避重试容灾。
  - **高级通道**：自填密钥，兼容 Kimi / DeepSeek / 通义千问 / 豆包 / GLM 等
    任意 OpenAI 兼容服务商；对锁死采样参数的模型（kimi-k3 等）自动降级适配。
- **数据存储**：全部本地 SQLite（对话记录、角色设定、记忆碎片、API 配置），
  除大模型推理请求外无任何数据外传。
- **核心功能**：性格克隆（导入 .txt 聊天记录 → 提取说话风格）、
  长期记忆（对话事实提炼 + 对话时自动召回注入，碎片可左滑删除）、
  作息模拟（睡眠时段用户可自定义，出厂 23:00–06:00）、后台主动消息推送。
- **氛围系统**：自定义聊天背景图 + 背景音乐（循环播放、音量调节）。

## 快速开始

1. `flutter pub get`
2. `flutter run`（或 `flutter build apk`）
3. 打开 App 即可对话（默认免费通道）。如需更稳定聪慧的回应：
   右上角「···」→ 通讯设置 → **连接配置** → 切换「高级通道」，
   填入服务地址 / 连接密钥 / 模型名称，点「测试连接」确认可用。
   - Kimi 参考配置：地址 `https://api.moonshot.cn/v1`，模型 `kimi-k3`
4. 「建立连接」导入聊天记录（.txt，格式 `Ta：...` / `我：...`），
   等待分析完成即可让 Ta"活过来"。

## 聊天记录导入

- 支持 UTF-8 / GBK 编码自动检测（兼容老版 QQ Windows 导出文件）
- 支持超大文件：>2MB 走流式读取（内存恒定，上限 200MB），
  自动按 头部20%/中部采样/尾部60% 智能摘取片段
- 最多同时合并 5 份文件

```
2020/11/22 10:20
Ta：莫西莫西～
Ta：还在干嘛！？
我：你谁？
```

## 项目结构

```
lib/
├── config/constants.dart            # 出厂默认配置与常量（双通道）
├── database/db_helper.dart          # SQLite（5张表，v3）
├── models/                          # ChatMessage / CharacterStyle
├── repositories/character_repository.dart
├── services/
│   ├── llm_api_service.dart         # 云端 API 统一接口层（容灾重试/参数自适应）
│   ├── chat_service.dart            # 对话约束引擎（洗涤/去重/记忆注入）
│   ├── import_service.dart          # .txt 流式导入（编码检测/三段采样）
│   ├── style_extraction_service.dart# 性格榨取（防幻觉三重过滤）
│   ├── memory_distillation_service.dart # 长期记忆提纯
│   ├── memory_recall_service.dart   # 记忆召回（RAG 垫片）
│   ├── ambience_service.dart        # 背景图/背景音乐管理
│   └── proactive_message_service.dart   # 后台主动消息
├── state/app_providers.dart         # Riverpod 状态层
├── screens/chat_screen.dart         # QQ 风格聊天界面（滑窗上下文/失败重发）
├── screens/settings_screen.dart     # 通讯设置（连接/氛围/睡眠时段）
└── main.dart                        # 入口 + 后台任务调度
```

## 测试

```
flutter analyze   # 须保持 No issues found!
flutter test      # 23 项测试（单元 + 真实聊天记录集成）
```
