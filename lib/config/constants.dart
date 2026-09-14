/// 全局常量配置
///
/// V6.0 重构：本地 Ollama 推理已移除，改为云端大模型 API（OpenAI 兼容协议）。
/// 实际生效的 baseUrl / apiKey / model 存储在 SQLite app_settings 表中，
/// 此处仅提供出厂默认值（DeepSeek），用户可在「通讯设置」中随时更换为
/// 任意 OpenAI 兼容服务商（通义 / 豆包 / Kimi / GLM 等）。
class AppConstants {
  // ── 出厂默认 API 配置 ────────────────────────────────────────────────────
  /// 默认 API 服务地址（不含 /chat/completions 后缀，拼接时自动补全）
  static const String defaultApiBaseUrl = 'https://api.deepseek.com';

  /// 默认对话模型
  static const String defaultModelName = 'deepseek-chat';

  // ── app_settings 表的键名 ────────────────────────────────────────────────
  static const String keyApiBaseUrl = 'api_base_url';
  static const String keyApiKey = 'api_key';
  static const String keyModelName = 'model_name';

  // ── 请求参数 ─────────────────────────────────────────────────────────────
  /// 日常对话请求超时（秒）
  /// 推理型模型（如 kimi-k3）生成前有较长的"思考"延迟，需留足余量
  static const int chatTimeoutSeconds = 60;

  /// 分析类长任务请求超时（秒）：性格提取 / 记忆提炼
  /// 输入为长文本切片 + 结构化 JSON 输出，推理型模型可能耗时数分钟
  static const int analysisTimeoutSeconds = 240;
}
