import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:huainian/config/constants.dart';
import 'package:huainian/database/db_helper.dart';
import 'package:huainian/services/llm_api_service.dart';

/// 单条事实碎片领域模型
class MemoryFact {
  final String factType;    // 事实分类：habit / preference / relationship / event / other
  final String factContent; // 事实文本，如"用户对花生过敏"
  final int? sourceMessageId;
  final double importanceScore; // 0.0~1.0

  const MemoryFact({
    required this.factType,
    required this.factContent,
    this.sourceMessageId,
    this.importanceScore = 0.5,
  });

  factory MemoryFact.fromJson(Map<String, dynamic> json) {
    return MemoryFact(
      factType: json['fact_type'] as String? ?? 'other',
      factContent: json['fact_content'] as String? ?? '',
      // clamp 防止模型返回越界值（如 1.2、-0.1）导致 UI 显示异常百分比
      importanceScore:
          ((json['importance_score'] as num?)?.toDouble() ?? 0.5)
              .clamp(0.0, 1.0),
    );
  }
}

/// 批次提炼进度回调
typedef DistillationProgressCallback = void Function({
  required int totalBatches,
  required int completedBatches,
  required int factsFound,
});

/// 阶段4.0 - 异步长期记忆提纯服务
/// 职责：读取conversations历史，以QA Pair批次调用大模型提炼事实，写入memory_facts表
/// V6.0：请求出口由本地 Ollama 切换为 LlmApiService（云端 API）。
class MemoryDistillationService {
  final LlmApiService _llmApi = LlmApiService();

  static const int _batchSize = 10;           // 每批处理的QA对数
  static const int _maxFactsPerBatch = 5;     // 每批最多写入的事实条数

  /// 执行全量记忆提纯
  /// [onProgress] 进度回调，可用于更新UI
  /// 返回本次写入的事实总数
  Future<int> distillAllMemories({
    DistillationProgressCallback? onProgress,
  }) async {
    final db = DbHelper.instance;

    // 读取全量对话历史
    final List<Map<String, dynamic>> allMessages = await db.getAllMessages();
    if (allMessages.isEmpty) {
      debugPrint('MemoryDistillationService: conversations表为空，跳过提炼');
      return 0;
    }

    // 组装QA Pair列表（user消息+紧随的assistant消息为一对）
    final List<Map<String, String>> qaPairs = _buildQaPairs(allMessages);
    if (qaPairs.isEmpty) {
      debugPrint('MemoryDistillationService: 无有效QA Pair，跳过提炼');
      return 0;
    }

    // 提炼前清空旧的memory_facts（覆盖式全量刷新）
    await db.clearMemoryFacts();

    final int totalBatches = (qaPairs.length / _batchSize).ceil();
    int totalFactsWritten = 0;

    for (int batchIndex = 0; batchIndex < totalBatches; batchIndex++) {
      final int start = batchIndex * _batchSize;
      final int end = (start + _batchSize).clamp(0, qaPairs.length);
      final List<Map<String, String>> batch = qaPairs.sublist(start, end);

      onProgress?.call(
        totalBatches: totalBatches,
        completedBatches: batchIndex,
        factsFound: totalFactsWritten,
      );

      try {
        final List<MemoryFact> facts = await _distillBatch(batch);
        for (final fact in facts) {
          if (fact.factContent.isNotEmpty) {
            await db.insertMemoryFact(fact);
            totalFactsWritten++;
          }
        }
        debugPrint(
          'MemoryDistillationService: 批次${batchIndex + 1}/$totalBatches 完成，'
          '本批提炼 ${facts.length} 条事实',
        );
      } catch (e) {
        // 单批失败不中断整体流水
        debugPrint('MemoryDistillationService [批次${batchIndex + 1}失败]: $e');
      }
    }

    onProgress?.call(
      totalBatches: totalBatches,
      completedBatches: totalBatches,
      factsFound: totalFactsWritten,
    );

    debugPrint('MemoryDistillationService: 全量提炼完成，共写入 $totalFactsWritten 条事实');
    return totalFactsWritten;
  }

  // ── 内部：组装QA Pair ───────────────────────────────────────────────────────
  List<Map<String, String>> _buildQaPairs(List<Map<String, dynamic>> messages) {
    final pairs = <Map<String, String>>[];
    for (int i = 0; i < messages.length - 1; i++) {
      final cur = messages[i];
      final next = messages[i + 1];
      if (cur['role'] == 'user' && next['role'] == 'assistant') {
        final userContent = cur['content'] as String? ?? '';
        final assistantContent = next['content'] as String? ?? '';
        if (userContent.isNotEmpty && assistantContent.isNotEmpty) {
          pairs.add({'user': userContent, 'assistant': assistantContent});
        }
        i++; // 跳过已处理的assistant消息
      }
    }
    return pairs;
  }

  // ── 内部：单批次提炼 ────────────────────────────────────────────────────────
  Future<List<MemoryFact>> _distillBatch(List<Map<String, String>> batch) async {
    final String systemPrompt = _buildDistillationSystemPrompt();
    final String userContent = _buildBatchContent(batch);

    final String rawResponse = await _doRequest([
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userContent},
    ]);

    return _parseFactsFromResponse(rawResponse);
  }

  // ── 内部：构建事实提炼System Prompt ─────────────────────────────────────────
  String _buildDistillationSystemPrompt() {
    return '''你是一名专业的对话记忆分析师。你的唯一任务是：从用户与AI助手的对话片段中，提炼出关于"用户"这个真实人物的具体事实碎片。

【核心原则 - 只提取用户信息】:
- 只关注"用户"（user角色）说的内容，不分析助手的回复。
- 提炼的是用户透露的真实信息：个人偏好、习惯、经历、关系、当下状态等。
- 绝对禁止推测和联想，只提炼对话中明确出现的事实。
- 若该批对话中找不到任何有价值的用户事实，直接返回空数组 []。

【fact_type分类规则】:
- habit: 用户的日常习惯（睡眠、饮食、作息等）
- preference: 用户的喜好与厌恶（食物、音乐、电影等）
- relationship: 用户提及的人际关系（朋友、家人、同事等）
- event: 用户提及的具体事件（今天做了什么、发生了什么）
- other: 不属于以上分类但有记忆价值的信息

【importance_score评分标准】:
- 1.0: 强烈情绪表达或反复提及的核心偏好（如"最讨厌"、"最喜欢"）
- 0.7: 明确表达的偏好或习惯
- 0.5: 一般性事实陈述
- 0.3: 偶然提及的次要信息

【输出铁律】:
1. 只输出JSON数组，不输出任何解释文字。
2. 数组中每个元素格式如下：
   {"fact_type": "<分类>", "fact_content": "<20字以内的精炼事实>", "importance_score": <0.0~1.0的小数>}
3. 每批最多输出 $_maxFactsPerBatch 条，优先选取importance_score最高的。
4. fact_content必须是以"用户"开头的第三人称陈述句，如"用户对猫毛过敏"、"用户喜欢听R&B音乐"。''';
  }

  // ── 内部：构建批次内容 ───────────────────────────────────────────────────────
  String _buildBatchContent(List<Map<String, String>> batch) {
    final sb = StringBuffer();
    sb.writeln('请从以下对话片段中提炼用户的事实碎片：');
    sb.writeln();
    for (int i = 0; i < batch.length; i++) {
      final pair = batch[i];
      sb.writeln('对话${i + 1}:');
      sb.writeln('  用户: ${pair['user']}');
      sb.writeln('  助手: ${pair['assistant']}');
    }
    sb.writeln();
    sb.writeln('输出JSON数组：');
    return sb.toString();
  }

  // ── 内部：解析事实列表 ───────────────────────────────────────────────────────
  List<MemoryFact> _parseFactsFromResponse(String rawText) {
    if (rawText.trim().isEmpty) return [];

    String jsonStr = rawText.trim();

    // 剥离Markdown代码块
    final mdCodeBlock = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
    final mdMatch = mdCodeBlock.firstMatch(jsonStr);
    if (mdMatch != null) {
      jsonStr = mdMatch.group(1)!.trim();
    }

    // 定位JSON数组
    final firstBracket = jsonStr.indexOf('[');
    final lastBracket = jsonStr.lastIndexOf(']');
    if (firstBracket == -1 || lastBracket == -1 || firstBracket >= lastBracket) {
      return [];
    }
    jsonStr = jsonStr.substring(firstBracket, lastBracket + 1);

    try {
      final List<dynamic> parsed = jsonDecode(jsonStr) as List<dynamic>;
      final List<MemoryFact> facts = parsed
          .whereType<Map<String, dynamic>>()
          .map((e) => MemoryFact.fromJson(e))
          .where((f) => f.factContent.isNotEmpty)
          .toList();
      // 截取前先按重要性降序排列：模型通常按对话时间顺序输出事实（最早对话在前），
      // 若直接 take() 则始终保留最早对话的事实，最新对话的事实因排在末尾被截断丢弃。
      // 排序后确保截取的永远是高价值事实，不受对话时间顺序影响。
      facts.sort((a, b) => b.importanceScore.compareTo(a.importanceScore));
      return facts.take(_maxFactsPerBatch).toList();
    } catch (e) {
      debugPrint('MemoryDistillationService [JSON解析失败]: $e\n原始: $rawText');
      return [];
    }
  }

  // ── 内部：API 请求（V6.0：经 LlmApiService 统一出口）───────────────────────
  Future<String> _doRequest(List<Map<String, String>> messages) async {
    try {
      return await _llmApi.chat(
        messages: messages,
        temperature: 0.1, // 极低温度确保事实提炼的确定性
        topP: 0.9,
        timeoutSeconds: AppConstants.analysisTimeoutSeconds,
      );
    } on LlmApiException catch (e) {
      throw Exception('记忆提炼请求失败: ${e.message}');
    }
  }

  void dispose() {
    _llmApi.dispose();
  }
}
