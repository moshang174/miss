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

  /// 接入方式：AppConstants.providerFree（免费通道）/ providerCustom（高级通道）
  final String provider;

  const LlmApiConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.provider = AppConstants.providerCustom,
  });

  bool get isFreeChannel => provider == AppConstants.providerFree;

  /// 免费通道无需密钥即可使用；高级通道必须配置密钥
  bool get isConfigured => isFreeChannel || apiKey.trim().isNotEmpty;

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

/// 内部信号：请求成功抵达服务端但返回非 200（携带状态码与原始错误体），
/// 供 400 参数自适应与 HTTP 错误映射使用；网络层重试对此类异常直接放行。
class _HttpFailureException implements Exception {
  final int statusCode;
  final String body;

  const _HttpFailureException(this.statusCode, this.body);
}

/// 从 SSE 流式响应文本中累积助手消息内容（delta.content）。
///
/// 推理过程字段（reasoning_content）与心跳/注释行一律忽略。
/// 返回值：null = 流中没有解析到任何有效数据块（异常响应）；
/// 空字符串 = 数据块存在但可见内容为空（推理型模型只输出了思考过程）。
@visibleForTesting
String? accumulateSseContent(String rawSse) {
  final buffer = StringBuffer();
  var sawValidChunk = false;
  for (final line in const LineSplitter().convert(rawSse)) {
    if (!line.startsWith('data:')) continue;
    final payload = line.substring(5).trimLeft();
    if (payload == '[DONE]') break;
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      final choices = json['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) continue;
      final delta = choices.first['delta'] as Map<String, dynamic>?;
      sawValidChunk = true;
      final piece = delta?['content'] as String?;
      if (piece != null) buffer.write(piece);
    } catch (_) {
      // 跳过不完整/非标的行（心跳、代理注入文本等），不中断整体解析
    }
  }
  return sawValidChunk ? buffer.toString() : null;
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
  ///
  /// 出厂默认 = 免费通道（providerFree）：新用户无需任何配置即可对话。
  /// 用户在通讯设置中切换为高级通道后，以 DB 中的地址/密钥/模型为准。
  Future<LlmApiConfig> loadConfig() async {
    final db = DbHelper.instance;
    String? provider = await db.getSetting(AppConstants.keyApiProvider);

    // 迁移兼容：V6.0 老用户没有 api_provider 键，但可能已配置高级通道密钥。
    // 此时按密钥存在性推断归属，避免升级后已保存的 Kimi/DeepSeek 配置被忽略。
    if (provider == null) {
      final legacyKey = await db.getSetting(AppConstants.keyApiKey);
      provider = (legacyKey != null && legacyKey.trim().isNotEmpty)
          ? AppConstants.providerCustom
          : AppConstants.providerFree;
    }

    // 免费通道：固定端点与模型，忽略密钥
    if (provider == AppConstants.providerFree) {
      return const LlmApiConfig(
        baseUrl: AppConstants.freeApiBaseUrl,
        apiKey: '',
        model: AppConstants.freeModelName,
        provider: AppConstants.providerFree,
      );
    }

    // 高级通道：DB 配置优先，缺省回落到出厂默认（DeepSeek 参考值）
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
      provider: AppConstants.providerCustom,
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
  /// 免费通道容灾：公共免费端点偶有故障（如 500/503），POST 失败后
  /// 自动回退到 GET 简易接口（自动精简上下文以适配 URL 长度限制）。
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

    // 免费通道容灾：公共端点故障为节点级间歇性（多节点轮询），
    // 每轮 POST→GET 两次尝试，共 3 轮，轮间退避 1s/2s，
    // 大幅提高命中健康节点概率
    if (config.isFreeChannel) {
      Object? lastError;
      for (int round = 0; round < 3; round++) {
        if (round > 0) {
          await Future.delayed(Duration(seconds: round));
        }
        try {
          return await _chatCompletions(
            config,
            messages: messages,
            temperature: temperature,
            topP: topP,
            timeoutSeconds: timeoutSeconds,
            maxTokens: maxTokens,
          );
        } on LlmApiException catch (e) {
          lastError = e;
          debugPrint(
              'LlmApiService: 免费通道第${round + 1}轮 POST 失败（${e.message}），尝试 GET 回退');
          try {
            return await _freeChannelGetFallback(
              config,
              messages,
              timeoutSeconds: timeoutSeconds,
            );
          } on LlmApiException catch (e2) {
            lastError = e2;
            debugPrint(
                'LlmApiService: 免费通道第${round + 1}轮 GET 回退失败（${e2.message}）');
          }
        }
      }
      throw LlmApiException(
          '免费通道暂时拥挤，请稍后重试，或前往通讯设置切换高级通道（$lastError）');
    }

    return await _chatCompletions(
      config,
      messages: messages,
      temperature: temperature,
      topP: topP,
      timeoutSeconds: timeoutSeconds,
      maxTokens: maxTokens,
    );
  }

  /// 标准 OpenAI chat completions POST 请求（含参数自适应重试）
  ///
  /// 一律以 stream: true 发起：推理型模型（如 kimi-k3）生成前有长达数分钟的
  /// "思考"期，非流式请求期间 TCP 连接完全空闲，极易被运营商 NAT /
  /// 防火墙 / 系统网络管理掐断（Software caused connection abort）。
  /// 流式响应字节持续流动，连接全程保持活跃，从机制上消除该故障。
  Future<String> _chatCompletions(
    LlmApiConfig config, {
    required List<Map<String, String>> messages,
    required double temperature,
    required double topP,
    int? timeoutSeconds,
    int? maxTokens,
  }) async {
    // 免费通道无密钥，不发送 Authorization 头
    final Map<String, String> headers = {
      'Content-Type': 'application/json; charset=utf-8',
      if (config.apiKey.isNotEmpty)
        'Authorization': 'Bearer ${config.apiKey}',
    };

    // 被服务端拒绝而剔除的采样参数名
    final Set<String> excludedParams = {};

    // 最多 1 + 2 次尝试：原始请求 + temperature/top_p 各被剔除一次
    for (int attempt = 0; attempt < 3; attempt++) {
      final Map<String, dynamic> requestBody = {
        'model': config.model,
        'messages': messages,
        'stream': true,
      };
      if (!excludedParams.contains('temperature')) {
        requestBody['temperature'] = temperature;
      }
      if (!excludedParams.contains('top_p')) {
        requestBody['top_p'] = topP;
      }
      if (maxTokens != null) requestBody['max_tokens'] = maxTokens;

      try {
        return await _postWithNetworkRetry(
          config,
          headers,
          requestBody,
          timeoutSeconds,
        );
      } on _HttpFailureException catch (failure) {
        // 400 参数错误：识别被拒参数，剔除后重试
        if (failure.statusCode == 400) {
          final String? rejected = _detectRejectedParam(failure.body);
          if (rejected != null && !excludedParams.contains(rejected)) {
            excludedParams.add(rejected);
            debugPrint(
                'LlmApiService: 模型拒绝参数 "$rejected"，已剔除并重试（第${attempt + 1}次）');
            continue;
          }
        }
        throw LlmApiException(
          _mapHttpError(failure.statusCode, failure.body),
          statusCode: failure.statusCode,
        );
      }
    }

    throw const LlmApiException('请求参数与服务端不兼容，请检查模型配置');
  }

  /// 单次请求的网络层重试封装
  ///
  /// 连接中断 / 超时等瞬态网络故障最多尝试 3 次（退避 1s / 2s）。
  /// 此前重试只存在于免费通道外层，高级通道（Kimi 等）的网络抖动
  /// 会直接抛给用户——性格提取等长请求首当其冲。
  ///
  /// 注意 http 1.x 会将底层 SocketException 包装为 [http.ClientException]
  /// （如 "Software caused connection abort"），它不是 SocketException
  /// 的子类，必须单独捕获，否则会落入兜底分支展示原始报错。
  Future<String> _postWithNetworkRetry(
    LlmApiConfig config,
    Map<String, String> headers,
    Map<String, dynamic> requestBody,
    int? timeoutSeconds,
  ) async {
    final totalTimeout =
        Duration(seconds: timeoutSeconds ?? AppConstants.chatTimeoutSeconds);
    LlmApiException? lastError;
    for (int netAttempt = 0; netAttempt < 3; netAttempt++) {
      if (netAttempt > 0) {
        debugPrint(
            'LlmApiService: 网络故障重试第$netAttempt次（${lastError?.message}）');
        await Future.delayed(Duration(seconds: netAttempt));
      }
      try {
        return await _postOnce(config, headers, requestBody)
            .timeout(totalTimeout);
      } on _HttpFailureException {
        // HTTP 层错误（4xx/5xx）不属于网络抖动，交给上层做参数自适应/错误映射
        rethrow;
      } on TimeoutException {
        lastError = const LlmApiException('连接超时，请检查网络后重试');
      } on SocketException {
        lastError = const LlmApiException('网络不可达，请检查网络连接');
      } on http.ClientException {
        lastError = const LlmApiException('网络连接被中断，请检查网络后重试');
      }
    }
    throw lastError!;
  }

  /// 执行一次流式 POST 请求，返回累积后的助手消息文本
  ///
  /// - 非 200：抛 [_HttpFailureException]（不重试，由上层判定）
  /// - 服务端忽略 stream 参数返回普通 JSON：按非流式解析（兼容路径）
  /// - SSE 流：60 秒无任何数据块视为连接假死，抛 TimeoutException 触发重试
  Future<String> _postOnce(
    LlmApiConfig config,
    Map<String, String> headers,
    Map<String, dynamic> requestBody,
  ) async {
    final request = http.Request('POST', Uri.parse(config.chatCompletionsUrl))
      ..headers.addAll(headers)
      ..body = jsonEncode(requestBody);

    final streamed = await _httpClient.send(request);

    if (streamed.statusCode != 200) {
      final errorBody = await streamed.stream.bytesToString();
      throw _HttpFailureException(streamed.statusCode, errorBody);
    }

    final contentType = streamed.headers['content-type'] ?? '';
    if (!contentType.contains('text/event-stream')) {
      // 兼容路径：服务端忽略 stream 标志，直接返回完整 JSON
      final bodyText = await streamed.stream.bytesToString();
      return _parseContentText(bodyText);
    }

    // SSE 流式累积：utf8 解码在字节流上做，跨数据块的多字节字符不会碎裂
    final rawSse = await streamed.stream
        .timeout(const Duration(seconds: 60))
        .transform(utf8.decoder)
        .join();

    final content = accumulateSseContent(rawSse);
    if (content == null) {
      throw const LlmApiException('服务返回了无法识别的流式响应');
    }
    return content;
  }

  // ── 免费通道 GET 回退 ─────────────────────────────────────────────────────
  // 公共免费端点的 POST /chat/completions 偶有服务端故障，
  // 回退到 GET https://host/{prompt}?system=...&model=... 简易接口。
  // GET 受 URL 长度限制（约 8KB），中文 URL 编码后体积膨胀约 9 倍，
  // 因此只保留 system 头部设定 + 最近 4 条消息，尽力而为。
  Future<String> _freeChannelGetFallback(
    LlmApiConfig config,
    List<Map<String, String>> messages, {
    int? timeoutSeconds,
  }) async {
    // 提取 system 设定（限长 700 字符，保头部红线与人格）
    String systemText = '';
    final history = <Map<String, String>>[];
    for (final m in messages) {
      if (m['role'] == 'system') {
        if (systemText.isEmpty) {
          final raw = m['content'] ?? '';
          systemText =
              raw.length > 700 ? raw.substring(0, 700) : raw;
        }
      } else {
        history.add(m);
      }
    }

    // 只保留最近 4 条消息，角色标签转为对话文本
    final recent = history.length > 4
        ? history.sublist(history.length - 4)
        : history;
    final promptText = recent
        .map((m) =>
            '${m['role'] == 'user' ? '对方' : '你'}：${m['content'] ?? ''}')
        .join('\n');

    if (promptText.trim().isEmpty) {
      throw const LlmApiException('免费通道暂不可用，请稍后重试或切换高级通道');
    }

    String base = config.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    // baseUrl 形如 https://text.pollinations.ai/openai，
    // GET 简易接口位于其域名根路径 /{prompt}
    final uri = Uri.parse(base);
    final root = '${uri.scheme}://${uri.host}';

    final queryParams = <String, String>{
      'model': config.model,
      if (systemText.isNotEmpty) 'system': systemText,
    };
    final url = Uri.parse('$root/${Uri.encodeComponent(promptText)}')
        .replace(queryParameters: queryParams);

    final http.Response response;
    try {
      response = await _httpClient.get(url).timeout(
            Duration(
                seconds: timeoutSeconds ?? AppConstants.chatTimeoutSeconds),
          );
    } on TimeoutException {
      throw const LlmApiException('连接超时，请检查网络后重试');
    } on SocketException {
      throw const LlmApiException('网络不可达，请检查网络连接');
    } on http.ClientException {
      throw const LlmApiException('网络连接被中断，请检查网络后重试');
    } catch (e) {
      throw LlmApiException('请求发送失败: $e');
    }

    if (response.statusCode != 200) {
      throw LlmApiException(
        '免费通道暂时拥挤（HTTP ${response.statusCode}），请稍后重试，'
        '或前往通讯设置切换高级通道',
        statusCode: response.statusCode,
      );
    }

    final text = utf8.decode(response.bodyBytes).trim();
    if (text.isEmpty) {
      throw const LlmApiException('免费通道返回了空回应，请稍后重试');
    }
    return text;
  }

  /// 从 400 错误响应中识别被拒绝的采样参数名（temperature / top_p）
  /// 未识别到时返回 null（属于其他类型的参数错误，不重试）
  String? _detectRejectedParam(String body) {
    final lower = body.toLowerCase();
    if (lower.contains('temperature')) return 'temperature';
    if (lower.contains('top_p')) return 'top_p';
    return null;
  }

  /// 解析 chat completions 成功响应（非流式兼容路径），提取助手消息文本
  String _parseContentText(String bodyText) {
    try {
      final data = jsonDecode(bodyText) as Map<String, dynamic>;
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
