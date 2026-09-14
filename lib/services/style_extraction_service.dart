import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:huainian/config/constants.dart';
import 'package:huainian/models/character_style.dart';
import 'package:huainian/services/llm_api_service.dart';

class ExtractionResult {
  final String characterName;
  final String personaPrompt;
  final CharacterStyle style;

  const ExtractionResult({
    required this.characterName,
    required this.personaPrompt,
    required this.style,
  });
}

/// 阶段3.5 - 大模型结构化性格榨取器
/// V6.0：请求出口由本地 Ollama 切换为 LlmApiService（云端 API）。
class StyleExtractionService {
  final LlmApiService _llmApi = LlmApiService();

  Future<ExtractionResult> extractStyle(String textSlice, {String? fullText}) async {
    if (textSlice.trim().isEmpty) {
      throw Exception('聊天记录切片为空，无法进行性格提取');
    }

    final String validationSource =
        (fullText != null && fullText.isNotEmpty) ? fullText : textSlice;

    final String systemPrompt = _buildExtractionSystemPrompt();
    final String userContent = _buildUserContent(textSlice);

    String rawResponse = await _requestExtraction(systemPrompt, userContent);
    ExtractionResult? result = _tryParseResponse(rawResponse, textSlice, validationSource);

    if (result == null) {
      debugPrint('StyleExtractionService: 首次解析失败，启动修正重试...');
      rawResponse = await _requestRepair(systemPrompt, userContent, rawResponse);
      result = _tryParseResponse(rawResponse, textSlice, validationSource);
    }

    if (result == null) {
      debugPrint('StyleExtractionService [原始响应]: $rawResponse');
      throw Exception('大模型未能输出有效JSON，请检查聊天记录格式或重试');
    }

    return result;
  }

  String _buildExtractionSystemPrompt() {
    return '''你是一名专业的人物风格分析师。你的唯一任务是：深度阅读用户给出的真实聊天记录，只从记录文本本身中提炼"Ta"这个人的说话风格特征。

【分析步骤 - 严格按顺序执行】

步骤1：识别"Ta"的发言
- 找到代表"Ta"的行标记格式，如"Ta："、"Ta:"、"Miko："等
- 分别统计"Ta"的发言和对方的发言，不要混淆

步骤2：量化说话长度
- 统计"Ta"每条消息的字数，计算平均值 → avg_length
- max_length 应为 avg_length 的 1.5 到 2.5 倍，不超过 80

步骤3：提取专属符号（最严格规则）
以下情况【一律不算专属符号】：
  ✗ 单字符重复序列：如 ↑↑↑↑、~~~~、！！！！、。。。（同一个字符连续出现3次以上）
  ✗ 情绪爆发时的临时修饰：仅在某次激动时出现一次，不是习惯性用法
  ✗ 标准汉字标点：。，！？……——等（这些人人都用）
可以算作专属符号的【必须满足以下所有条件】：
  ✓ 是特殊符号或颜文字（如 ~、(● ｀∀´ ●)╯ 等非标准字符）
  ✓ 在"Ta"的消息中出现 2 次以上（颜文字5字符以上可1次）
  ✓ 在原文中可逐字找到

步骤4：提取口头禅
- 只收录"Ta"明显重复使用的词语（如"哈哈哈"、"哼哼"等）
- 必须在原文中实际出现，不可推断

步骤5：摘录特征表达
- 从原文中逐字复制3至5条"Ta"最有代表性的短句
- 只选能体现"Ta"独特说话方式的句子，不选平淡的日常对话

步骤6：撰写人格描述（100-150字）
按以下4个维度描述"Ta"的性格与风格，合并成连贯的中文段落：
  1. 性格底色（开朗/内向/傲娇/温柔/暴躁等）
  2. 情感表达方式（直说/用行动/否认/撒娇等）
  3. 说话习惯（简短直接/爱用疑问句/喜欢反问/调侃等）
  4. 对待对话者的态度（在乎却嘴硬/漠不关心/主动黏人等）

【输出格式 - 不可违反】
你的回复必须是且仅是一个合法的 JSON 对象，不允许输出任何 JSON 以外的文字。
严格按照以下结构，字段名完全匹配：

{
  "_analysis_notes": "写下你在步骤1-5的统计过程，例如：Ta共23条消息，平均9字；符号'~'出现3次；'↑↑↑↑'只出现1次且为情绪爆发不符合条件",
  "character_name": "Ta的简短称呼，2至6个字，可以是中文名、英文名或混合名",
  "persona_prompt": "100-150字的人格描述，覆盖上述4个维度，第二人称，纯文字无特殊符号",
  "avg_length": <整数>,
  "max_length": <整数>,
  "allowed_symbols": ["只填写通过步骤3所有判断条件的符号，找不到填 []"],
  "modal_particles": ["只填写步骤4确认的口头禅，找不到填 []"],
  "tone_guide": ["逐字摘录3-5条原文短句，找不到填 []"]
}''';
  }

  String _buildUserContent(String textSlice) {
    return '''请仔细阅读以下聊天记录，严格按照系统指令的分析步骤，只从原文中提取"Ta"的风格特征：

---
$textSlice
---

输出符合要求的JSON对象。''';
  }

  Future<String> _requestExtraction(String systemPrompt, String userContent) async {
    return _doRequest([
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userContent},
    ]);
  }

  Future<String> _requestRepair(
      String systemPrompt, String userContent, String brokenResponse) async {
    return _doRequest([
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userContent},
      {'role': 'assistant', 'content': brokenResponse},
      {
        'role': 'user',
        'content': '你的上一个回复不是合法的JSON格式。请重新输出，只输出纯JSON对象，不要包含任何其他文字。',
      },
    ]);
  }

  /// V6.0：经 LlmApiService 统一出口，低温确保分析任务确定性
  Future<String> _doRequest(List<Map<String, String>> messages) async {
    try {
      return await _llmApi.chat(
        messages: messages,
        temperature: 0.2,
        topP: 0.9,
        timeoutSeconds: AppConstants.analysisTimeoutSeconds,
      );
    } on LlmApiException catch (e) {
      throw Exception(e.message);
    }
  }

  ExtractionResult? _tryParseResponse(
      String rawText, String originalSlice, String validationSource) {
    if (rawText.trim().isEmpty) return null;

    String jsonStr = rawText.trim();

    // 剥离 markdown 代码块
    final mdCodeBlock = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
    final mdMatch = mdCodeBlock.firstMatch(jsonStr);
    if (mdMatch != null) jsonStr = mdMatch.group(1)!.trim();

    // 提取最外层 {} 对
    final firstBrace = jsonStr.indexOf('{');
    final lastBrace = jsonStr.lastIndexOf('}');
    if (firstBrace == -1 || lastBrace == -1 || firstBrace >= lastBrace) return null;
    jsonStr = jsonStr.substring(firstBrace, lastBrace + 1);

    try {
      final Map<String, dynamic> parsed = jsonDecode(jsonStr) as Map<String, dynamic>;
      return _mapToResult(parsed, originalSlice, validationSource);
    } catch (e) {
      debugPrint('StyleExtractionService [JSON解析失败]: $e');
      return null;
    }
  }

  ExtractionResult _mapToResult(
      Map<String, dynamic> data, String originalSlice, String validationSource) {
    final characterName = (data['character_name'] as String?)?.trim();
    final personaRaw = (data['persona_prompt'] as String?)?.trim();
    final avgLength = (data['avg_length'] as int?) ?? 15;

    // max_length 合法性校验：比例超出 1.0~3.0 或绝对值超过 80 时修正
    final rawMax = data['max_length'] as int?;
    final int maxLength;
    if (rawMax == null) {
      maxLength = (avgLength * 2).clamp(10, 60);
    } else {
      final double ratio = rawMax / avgLength.clamp(1, 100);
      if (ratio < 1.0 || ratio > 3.0 || rawMax > 80) {
        debugPrint(
          'StyleExtractionService [字数修正]: LLM给出max_length=$rawMax '
          '(avg=$avgLength, ratio=${ratio.toStringAsFixed(2)})，已修正为${(avgLength * 2).clamp(10, 60)}',
        );
        maxLength = (avgLength * 2).clamp(10, 60);
      } else {
        maxLength = rawMax.clamp(5, 80);
      }
    }

    // 原始符号列表
    final rawSymbols = (data['allowed_symbols'] as List?)
            ?.map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList() ??
        [];

    final rawParticles = (data['modal_particles'] as List?)
            ?.map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList() ??
        [];

    final rawToneGuide = (data['tone_guide'] as List?)
            ?.map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList() ??
        [];

    // 符号：三重过滤（结构噪音 + 原文核验 + Ta行频次）
    final allowedSymbols = _validateSymbols(rawSymbols, validationSource);

    // 口头禅：原文核验（简单 contains，不限频次）
    final modalParticles = _postValidateByContains(rawParticles, validationSource);

    // 特征表达：原文核验（必须能在原文中找到）
    final toneGuide = _postValidateByContains(rawToneGuide, validationSource);

    _logFilterDiff('专属符号', rawSymbols, allowedSymbols);
    _logFilterDiff('口头禅', rawParticles, modalParticles);
    _logFilterDiff('特征表达', rawToneGuide, toneGuide);

    final name =
        (characterName != null && characterName.isNotEmpty) ? characterName : '神秘来者';
    final persona = (personaRaw != null && personaRaw.isNotEmpty)
        ? personaRaw
        : '你是用户的聊天伙伴，性格真实，说话方式自然。';

    final style = CharacterStyle(
      avgLength: avgLength.clamp(3, 100),
      maxLength: maxLength,
      allowedSymbols: allowedSymbols,
      modalParticles: modalParticles,
      toneGuide: toneGuide,
    );

    return ExtractionResult(
      characterName: name,
      personaPrompt: persona,
      style: style,
    );
  }

  // ── 三重符号过滤器 ──────────────────────────────────────────────────────────

  List<String> _validateSymbols(List<String> rawSymbols, String validationSource) {
    // 提前统计"Ta的发言行"数量，如果格式不是标准的"Ta："则跳过频次过滤
    final int totalTaLines = _countTaDialogueLines(validationSource);
    final bool useFrequencyFilter = totalTaLines >= 3;

    final List<String> result = [];
    for (final s in rawSymbols) {
      if (s.isEmpty) continue;

      // 过滤1：结构噪音（同一字符重复 3 次以上）
      if (_isStructuralNoise(s)) {
        debugPrint('StyleExtractionService [结构噪音]: "$s" → 单字符重复序列，已剔除');
        continue;
      }

      // 过滤2：原文必须存在
      if (!validationSource.contains(s)) {
        debugPrint('StyleExtractionService [幻觉]: "$s" → 原文中找不到，已剔除');
        continue;
      }

      // 过滤3：Ta行出现频次
      // 短符号（<5字符）需 ≥2 次；长颜文字（≥5字符）需 ≥1 次
      if (useFrequencyFilter) {
        final int taCount = _countInTaLines(s, validationSource);
        final int minCount = s.runes.length >= 5 ? 1 : 2;
        if (taCount < minCount) {
          debugPrint(
            'StyleExtractionService [频次]: "$s" → Ta行中出现 $taCount 次（需≥$minCount），已剔除',
          );
          continue;
        }
      }

      result.add(s);
    }
    return result;
  }

  /// 判断是否为结构噪音：长度 ≥ 3 且所有 Unicode 码点相同
  bool _isStructuralNoise(String s) {
    final runes = s.runes.toList();
    if (runes.length < 3) return false;
    final int first = runes.first;
    return runes.every((r) => r == first);
  }

  /// 统计以"Ta："或"Ta:"开头的行数量（用于判断是否适合做频次过滤）
  int _countTaDialogueLines(String text) {
    int count = 0;
    for (final line in text.split('\n')) {
      if (line.startsWith('Ta：') || line.startsWith('Ta:')) count++;
    }
    return count;
  }

  /// 统计候选字符串在 Ta 发言行中出现的次数
  int _countInTaLines(String candidate, String text) {
    int count = 0;
    for (final line in text.split('\n')) {
      if ((line.startsWith('Ta：') || line.startsWith('Ta:')) &&
          line.contains(candidate)) {
        count++;
      }
    }
    return count;
  }

  /// 简单原文核验：只要在原文中 contains 即通过（用于口头禅、特征表达）
  List<String> _postValidateByContains(List<String> candidates, String source) {
    return candidates.where((s) => s.isNotEmpty && source.contains(s)).toList();
  }

  void _logFilterDiff(String label, List<String> before, List<String> after) {
    if (before.length == after.length) return;
    final removed = before.toSet().difference(after.toSet());
    debugPrint('StyleExtractionService [$label过滤]: 剔除 $removed');
  }

  void dispose() => _llmApi.dispose();
}
