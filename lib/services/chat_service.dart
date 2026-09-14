import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:huainian/models/character_style.dart';
import 'package:huainian/repositories/character_repository.dart';
import 'package:huainian/services/llm_api_service.dart';
import 'package:huainian/services/memory_recall_service.dart';

/// 异次元通讯 - 核心对话服务
/// V6.0：推理底座由本地 Ollama 切换为云端大模型 API（LlmApiService）。
/// 保留全部约束引擎：System Prompt 构建、记忆垫片注入、白名单后置拦截、
/// 同输入历史去重重采样。
class ChatService {
  final CharacterRepository _characterRepository = CharacterRepository();
  final LlmApiService _llmApi = LlmApiService();
  final Random _random = Random();

  /// 内存级同输入历史回复缓存（Key: 归一化用户输入, Value: 历史回复列表）
  final Map<String, List<String>> _usedReplies = {};

  /// 阶段4.5：记忆碎片召回服务（字符级相似度，BGE-M3升级时替换内部实现）
  final MemoryRecallService _recallService = MemoryRecallService();

  /// 上一轮 sendChatMessage 实际注入 System Prompt 的记忆碎片文本
  /// UI层读取此值可显示本轮"记忆激活"信息（调试/演示用）
  List<String> _lastRecalledFacts = [];
  List<String> get lastRecalledFacts => List.unmodifiable(_lastRecalledFacts);

  static const int _maxRetryCount = 3;

  /// 去重判定的 Jaccard 相似度阈值：≥ 0.6 视为重复
  /// 比原版"包含关系"判定更精准：短词包含长词不再误判为重复
  static const double _duplicateThreshold = 0.6;

  Future<String> sendChatMessage(List<Map<String, String>> messages) async {
    try {
      // 1. 提取用户输入，归一化后作为去重 Key
      String rawUserInput = '';
      try {
        rawUserInput = messages.lastWhere((m) => m['role'] == 'user')['content'] ?? '';
      } catch (_) {}

      // Key 归一化："在吗" 与 "在吗？" 落到同一去重桶
      final String dedupeKey = _normalizeKey(rawUserInput);

      // 2. 获取角色配置
      CharacterStyle style = CharacterStyle.fallback();
      String basePersona = "你正在模拟用户的微信情感伴侣。";
      try {
        final config = await _characterRepository.getCharacterConfig();
        if (config != null) {
          style = config.style;
          if (config.personaPrompt.isNotEmpty) {
            basePersona = config.personaPrompt;
          }
        }
      } catch (dbError) {
        debugPrint('ChatService [数据库异常]: 采用系统默认兜底风格。原因: $dbError');
      }

      // 3. 从memory_facts召回相关记忆碎片，作为回忆垫片注入System Prompt
      _lastRecalledFacts = await _recallService.recallByQuery(rawUserInput);
      final String baseSystemPrompt = _buildSystemPrompt(basePersona, style,
          memoryPadding: _lastRecalledFacts);

      // 4. 构建基础消息队列
      final List<Map<String, String>> baseMessages = _injectSystemPrompt(messages, baseSystemPrompt);

      // 5. 核心去重重试循环
      String finalCleanReply = '';
      int currentRetry = 0;
      List<Map<String, String>> activeMessages = List.from(baseMessages);

      while (currentRetry <= _maxRetryCount) {
        // 重试时动态升高 temperature，强制模型探索更宽的分布区间
        final double currentTemperature = currentRetry == 0
            ? 0.75
            : (0.75 + currentRetry * 0.1).clamp(0.75, 1.2);

        final String rawReply = await _executeRequest(
          activeMessages,
          temperature: currentTemperature,
        );

        if (rawReply.startsWith('错误：') || rawReply.startsWith('异常：')) {
          return rawReply;
        }

        finalCleanReply = _applyPostInterceptor(rawReply, style);

        if (dedupeKey.isEmpty) break;

        final List<String> historyReplies = _usedReplies[dedupeKey] ?? [];

        if (!_isDuplicateReply(finalCleanReply, historyReplies)) {
          break;
        }

        currentRetry++;
        debugPrint(
          '【去重拦截器触发】: 输入"$dedupeKey" 回复"$finalCleanReply" 命中重复，'
          '发起第$currentRetry次重采样 (temperature=$currentTemperature)...',
        );

        // 反向干预：明确列出所有已使用过的回复，模型才能有针对性地绕开
        final String usedRepliesSummary = historyReplies
            .map((r) => '"$r"')
            .join('、');
        activeMessages.add({
          'role': 'system',
          'content': '注意：对于用户刚才说的话，你已经回复过：$usedRepliesSummary。'
              '这些回复用户都听腻了。请给出一个和上面所有回复在内容和语气上都完全不同的新回复，字数控制在5字以内。',
        });
      }

      // 6. 录入去重指纹库
      if (dedupeKey.isNotEmpty && finalCleanReply.isNotEmpty) {
        _usedReplies.putIfAbsent(dedupeKey, () => []);
        _usedReplies[dedupeKey]!.add(finalCleanReply);
        // 内存水位防御：超过8条时移除最早记录
        if (_usedReplies[dedupeKey]!.length > 8) {
          _usedReplies[dedupeKey]!.removeAt(0);
        }
      }

      return finalCleanReply;
    } catch (e) {
      return '异常：对话服务链路遭遇未知故障: $e';
    }
  }

  // ── 归一化 Key ────────────────────────────────────────────────────────────
  // 去除首尾空白、全部标点和空格，转为纯汉字+字母数字的规范形式。
  // "在吗"、"在吗？"、" 在吗 " 全部归一化为 "在吗"，落到同一去重桶。
  String _normalizeKey(String input) {
    if (input.isEmpty) return '';
    // 保留汉字、英文字母、数字，其余全部去除
    return input.replaceAll(RegExp(r'[^一-龥a-zA-Z0-9]'), '').toLowerCase().trim();
  }

  // ── System Prompt 构建（含记忆垫片可选注入）────────────────────────────────
  String _buildSystemPrompt(String basePersona, CharacterStyle style,
      {List<String> memoryPadding = const []}) {
    final String factsStr = memoryPadding.map((f) => '- $f').join('\n');
    final String memoryBlock = memoryPadding.isEmpty
        ? ''
        : '【TA对你的了解（潜移默化融入对话，切勿原文引用或明说"你曾告诉我"）】:\n$factsStr\n\n';
    return '''$basePersona

$memoryBlock【极端全局红线命令】:
1. 你必须且只能输出纯文字，严禁在回复中生成任何中英文括号（如 "()"、"（）"）、任何中括号、花括号、星号、斜杠、表情符号、Emoji 或自定义颜文字符号！
2. 严禁进行任何自我解释、长篇大论或打破第四面墙，直接切入对话。
3. 你的全部回复字数必须受到极度克制，尽量精简。

${style.toPromptConstraints()}
''';
  }

  List<Map<String, String>> _injectSystemPrompt(
    List<Map<String, String>> messages,
    String systemPrompt,
  ) {
    final List<Map<String, String>> result = [];
    bool injected = false;
    for (final msg in messages) {
      if (msg['role'] == 'system') {
        result.add({'role': 'system', 'content': systemPrompt});
        injected = true;
      } else {
        result.add(msg);
      }
    }
    if (!injected) {
      result.insert(0, {'role': 'system', 'content': systemPrompt});
    }
    return result;
  }

  // ── API 请求（V6.0：经 LlmApiService 统一出口）───────────────────────────
  /// 保持历史契约：失败时返回以 '错误：' / '异常：' 开头的字符串而非抛异常，
  /// 供 ProactiveMessageService 等调用方做前缀判定。
  Future<String> _executeRequest(
    List<Map<String, String>> messages, {
    double temperature = 0.75,
  }) async {
    try {
      return await _llmApi.chat(
        messages: messages,
        temperature: temperature,
        topP: 0.85,
      );
    } on LlmApiException catch (e) {
      return '异常：${e.message}';
    } catch (e) {
      return '异常：请求崩溃: $e';
    }
  }

  // ── 后置拦截洗涤器 (白名单版) ────────────────────────────────────────────
  String _applyPostInterceptor(String rawText, CharacterStyle style) {
    if (rawText.isEmpty) return '哼';

    final RegExp purifyRegex = RegExp(r'[^一-龥a-zA-Z0-9，。！？\.,!\?]');
    String cleanText = rawText.replaceAll(purifyRegex, '');
    cleanText = cleanText.replaceAll(RegExp(r'[，。！？\.,!\?]{2,}'), '。');

    if (cleanText.length > style.maxLength) {
      cleanText = cleanText.substring(0, style.maxLength);
    }
    cleanText = cleanText.replaceAll(RegExp(r'[，。！？\.,!\?]$'), '');

    if (cleanText.isEmpty) cleanText = '哼';

    if (style.allowedSymbols.isNotEmpty) {
      cleanText += style.allowedSymbols[_random.nextInt(style.allowedSymbols.length)];
    }

    return cleanText;
  }

  // ── 去重判定（Jaccard 字符集相似度）────────────────────────────────────────
  // 计算纯汉字字符集的 Jaccard 相似度 = |A∩B| / |A∪B|
  //   ≥ 0.6（60% 字符重叠）才判定为重复
  //   既能捕捉"嗯在呢" vs "在呢呀" 这类高度相似的回复
  //   又能保护"好啊" vs "在啊" 这类低相似度的短回复不被误判
  bool _isDuplicateReply(String newReply, List<String> historyReplies) {
    final RegExp nonChinese = RegExp(r'[^一-龥]');
    final String newBase = newReply.replaceAll(nonChinese, '');

    // 极短回复（≤1字）不参与重复判定，防止误伤单字正常回应
    if (newBase.length <= 1) return false;

    final Set<String> newChars = newBase.split('').toSet();

    for (final oldReply in historyReplies) {
      final String oldBase = oldReply.replaceAll(nonChinese, '');
      if (oldBase.isEmpty) continue;

      final Set<String> oldChars = oldBase.split('').toSet();
      final int intersection = newChars.intersection(oldChars).length;
      final int union = newChars.union(oldChars).length;
      if (union == 0) continue;

      final double similarity = intersection / union;
      if (similarity >= _duplicateThreshold) {
        debugPrint(
          '【去重判定】: "$newBase" vs "$oldBase" → Jaccard=$similarity ≥ $_duplicateThreshold，判定为重复',
        );
        return true;
      }
    }
    return false;
  }

  void clearDeduplicationCache() {
    _usedReplies.clear();
  }

  /// 检查当前系统时间是否处于角色休眠时段
  /// 支持跨午夜时段，如 23:00 → 06:00
  /// [sleepStart] / [sleepEnd] 格式均为 "HH:MM"
  /// 解析失败时安全降级：返回 false（不休眠）
  static bool isInSleepRange(String sleepStart, String sleepEnd) {
    try {
      final now = DateTime.now();
      final curMin = now.hour * 60 + now.minute;
      final sp = sleepStart.split(':');
      final ep = sleepEnd.split(':');
      final startMin = int.parse(sp[0]) * 60 + int.parse(sp[1]);
      final endMin = int.parse(ep[0]) * 60 + int.parse(ep[1]);
      // 跨午夜：如 23:00 → 06:00
      if (startMin > endMin) {
        return curMin >= startMin || curMin < endMin;
      }
      // 同日时段：如 12:00 → 14:00
      return curMin >= startMin && curMin < endMin;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _llmApi.dispose();
  }
}
