/// 全局常量配置
///
/// V6.0 重构：本地 Ollama 推理已移除，改为云端大模型 API（OpenAI 兼容协议）。
/// V7.0：新增「接入方式」概念——出厂默认免费通道（无需密钥，开箱即用），
/// 用户可随时切换高级通道，自行填入任意 OpenAI 兼容服务商的密钥
/// （Kimi / DeepSeek / 通义 / 豆包 / GLM 等）以获得更高质量的回应。
class AppConstants {
  // ── 接入方式 ────────────────────────────────────────────────────────────
  /// 免费通道：无需密钥，开箱即用（公共免费端点，速度与稳定性有限）
  static const String providerFree = 'free';

  /// 高级通道：用户自定义 服务地址 / 密钥 / 模型
  static const String providerCustom = 'custom';

  // ── 免费通道配置（Pollinations 公共免费 OpenAI 兼容端点）──────────────────
  static const String freeApiBaseUrl = 'https://text.pollinations.ai/openai';
  static const String freeModelName = 'openai';

  // ── 高级通道出厂默认（DeepSeek，供用户参考填写）─────────────────────────
  static const String defaultApiBaseUrl = 'https://api.deepseek.com';
  static const String defaultModelName = 'deepseek-chat';

  // ── app_settings 表的键名 ────────────────────────────────────────────────
  static const String keyApiProvider = 'api_provider';
  static const String keyApiBaseUrl = 'api_base_url';
  static const String keyApiKey = 'api_key';
  static const String keyModelName = 'model_name';

  // ── 氛围设置键名（V7.0）──────────────────────────────────────────────────
  static const String keyChatBgPath = 'chat_bg_path';
  static const String keyBgmPath = 'bgm_path';
  static const String keyBgmEnabled = 'bgm_enabled';
  static const String keyBgmVolume = 'bgm_volume';

  // ── 请求参数 ─────────────────────────────────────────────────────────────
  /// 日常对话请求超时（秒）
  /// 推理型模型（如 kimi-k3）生成前有较长的"思考"延迟，需留足余量
  static const int chatTimeoutSeconds = 60;

  /// 分析类长任务请求超时（秒）：性格提取 / 记忆提炼
  /// 输入为长文本切片 + 结构化 JSON 输出，推理型模型可能耗时数分钟
  static const int analysisTimeoutSeconds = 240;
}
