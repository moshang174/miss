import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:huainian/config/constants.dart';
import 'package:huainian/database/db_helper.dart';

/// 大模型 API 配置（OpenAI 兼容协议）
@immutable
class LlmApiConfig {
  final String baseUrl;
  final String apiKey;
  final String model;

  const LlmApiConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  bool get isConfigured => apiKey.trim().isNotEmpty;

  /// 拼接完整的 chat completions 端点
  /// 兼容用户填写 "https://api.xxx.com"、"https://api.xxx.com/v1"
  /// 或完整路径 ".../v1/chat/completions" 的三种情况
  String get chatCompletionsUrl {
    String base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/chat/completions')) return base;
    return '$base/chat/completions';
  }
}

/// API 调用异常（message 面向用户友好展示）
class LlmApiException implements Exception {
  final String message;
  final int? statusCode;

  const LlmApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// V6.0 — 云端大模型 API 统一接口层
///
/// 职责：
///   1. 从 app_settings 表读取 API 配置（baseUrl / apiKey / model）
///   2. 以 OpenAI 兼容协议（POST /chat/completions）发起请求
///   3. 统一的超时控制与友好错误映射
///
/// 所有需要大模型能力的服务（对话 / 性格提取 / 记忆提炼 / 主动消息）
/// 一律经由本服务发出请求，不直接持有 http 细节。
class LlmApiService {
  final http.Client _httpClient = http.Client();

  /// 读取当前生效的 API 配置（DB 值优先，缺省回落到出厂默认）
  Future<LlmApiConfig> loadConfig() async {
    final db = DbHelper.instance;
    final baseUrl = await db.getSetting(AppConstants.keyApiBaseUrl);
    final apiKey = await db.getSetting(AppConstants.keyApiKey);
    final model = await db.getSetting(AppConstants.keyModelName);
    return LlmApiConfig(
      baseUrl: (baseUrl != null && baseUrl.trim().isNotEmpty)
          ? baseUrl.trim()
          : AppConstants.defaultApiBaseUrl,
      apiKey: apiKey?.trim() ?? '',
      model: (model != null && model.trim().isNotEmpty)
          ? model.trim()
          : AppConstants.defaultModelName,
    );
  }

  /// 发起一次 chat completions 请求，返回助手消息文本
  ///
  /// [messages]        OpenAI 格式消息数组（role: system/user/assistant）
  /// [temperature]     采样温度，由调用方按任务类型指定
  /// [topP]            nucleus 采样参数
  /// [timeoutSeconds]  超时秒数，默认走对话级超时
  /// [maxTokens]       输出上限，null 表示不限制（由服务端默认决定）
  ///
  /// 参数自适应：部分模型（如 kimi-k3、OpenAI o 系列）锁死采样参数，
  /// 收到 400 参数错误时自动识别被拒参数（temperature/top_p）并剔除重试，
  /// 调用方无需感知服务商差异。
  ///
  /// 抛出 [LlmApiException]：密钥未配置 / 网络故障 / HTTP 错误 / 响应格式异常
  Future<String> chat({
    required List<Map<String, String>> messages,
    double temperature = 0.75,
    double topP = 0.85,
    int? timeoutSeconds,
    int? maxTokens,
  }) async {
    final config = await loadConfig();
    if (!config.isConfigured) {
      throw const LlmApiException('连接密钥尚未配置，请前往通讯设置完成配置');
    }

    // 被服务端拒绝而剔除的采样参数名
    final Set<String> excludedParams = {};

    // 最多 1 + 2 次尝试：原始请求 + temperature/top_p 各被剔除一次
    for (int attempt = 0; attempt < 3; attempt++) {
      final Map<String, dynamic> requestBody = {
        'model': config.model,
        'messages': messages,
        'stream': false,
      };
      if (!excludedParams.contains('temperature')) {
        requestBody['temperature'] = temperature;
      }
      if (!excludedParams.contains('top_p')) {
        requestBody['top_p'] = topP;
      }
      if (maxTokens != null) requestBody['max_tokens'] = maxTokens;

      final http.Response response;
      try {
        response = await _httpClient
            .post(
              Uri.parse(config.chatCompletionsUrl),
              headers: {
                'Content-Type': 'application/json; charset=utf-8',
                'Authorization': 'Bearer ${config.apiKey}',
              },
              body: jsonEncode(requestBody),
            )
            .timeout(Duration(
                seconds:
                    timeoutSeconds ?? AppConstants.chatTimeoutSeconds));
      } on TimeoutException {
        throw const LlmApiException('连接超时，请检查网络后重试');
      } on SocketException {
        throw const LlmApiException('网络不可达，请检查网络连接');
      } catch (e) {
        throw LlmApiException('请求发送失败: $e');
      }

      // 400 参数错误：识别被拒参数，剔除后重试
      if (response.statusCode == 400) {
        final String? rejected = _detectRejectedParam(response.body);
        if (rejected != null && !excludedParams.contains(rejected)) {
          excludedParams.add(rejected);
          debugPrint(
              'LlmApiService: 模型拒绝参数 "$rejected"，已剔除并重试（第${attempt + 1}次）');
          continue;
        }
      }

      if (response.statusCode != 200) {
        throw LlmApiException(
          _mapHttpError(response.statusCode, response.body),
          statusCode: response.statusCode,
        );
      }

      return _parseContent(response);
    }

    throw const LlmApiException('请求参数与服务端不兼容，请检查模型配置');
  }

  /// 从 400 错误响应中识别被拒绝的采样参数名（temperature / top_p）
  /// 未识别到时返回 null（属于其他类型的参数错误，不重试）
  String? _detectRejectedParam(String body) {
    final lower = body.toLowerCase();
    if (lower.contains('temperature')) return 'temperature';
    if (lower.contains('top_p')) return 'top_p';
    return null;
  }

  /// 解析 chat completions 成功响应，提取助手消息文本
  String _parseContent(http.Response response) {
    try {
      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final choices = data['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) {
        throw const LlmApiException('服务返回了空响应');
      }
      final first = choices.first as Map<String, dynamic>;
      final message = first['message'] as Map<String, dynamic>?;
      final content = message?['content'] as String?;
      if (content == null) {
        throw const LlmApiException('服务响应缺少消息内容');
      }
      return content;
    } on LlmApiException {
      rethrow;
    } catch (e) {
      throw LlmApiException('响应解析失败: $e');
    }
  }

  /// 连通性测试：以最小代价发一条消息，验证密钥/地址/模型三者可用。
  /// 成功返回模型回复的短文本；失败抛出 [LlmApiException]。
  ///
  /// maxTokens 给到 64：推理型模型（如 kimi-k3）会先消耗思考 token，
  /// 额度过小会导致可见内容为空，误判为链路异常。
  Future<String> testConnection() async {
    final reply = await chat(
      messages: const [
        {'role': 'user', 'content': 'ping'}
      ],
      temperature: 0.1,
      maxTokens: 64,
      timeoutSeconds: 60,
    );
    // 推理型模型在极小额度下可能只产出思考过程、可见内容为空，
    // 空回应同样证明 地址/密钥/模型 三者链路正常
    return reply.trim().isEmpty ? '（模型回应为空，但链路正常）' : reply;
  }

  /// HTTP 状态码 → 用户友好错误文案
  String _mapHttpError(int statusCode, String body) {
    String detail = '';
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final err = data['error'] as Map<String, dynamic>?;
      final msg = err?['message'] as String?;
      if (msg != null && msg.isNotEmpty) {
        detail = msg.length > 80 ? '${msg.substring(0, 80)}…' : msg;
      }
    } catch (_) {
      // 非 JSON 错误体，忽略细节
    }

    switch (statusCode) {
      case 400:
        return '请求参数有误${detail.isNotEmpty ? ': $detail' : ''}';
      case 401:
      case 403:
        return '连接密钥无效或已过期，请前往通讯设置检查';
      case 404:
        return '接口地址或模型名称不存在，请检查通讯设置中的配置';
      case 429:
        return '请求过于频繁或额度不足，请稍后再试';
      case 500:
      case 502:
      case 503:
        return '服务端暂时异常，请稍后再试';
      default:
        return '服务响应异常 (HTTP $statusCode)${detail.isNotEmpty ? ': $detail' : ''}';
    }
  }

  void dispose() {
    _httpClient.close();
  }
}
