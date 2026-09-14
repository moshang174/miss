import 'package:flutter/foundation.dart';
import 'package:huainian/database/db_helper.dart';

/// 阶段4.5 — 本地记忆碎片相关性召回服务
///
/// 架构定位：
///   ChatService 在每轮 sendChatMessage 前调用本服务，获取与当前用户输入
///   最相关的 top-K 条记忆碎片文本，注入 System Prompt 作为"回忆垫片"，
///   使角色能无感融合共同记忆进行回复。
///
/// 当前算法：
///   字符集覆盖率（query-side）× _relevanceWeight
///   + DB 存储的 importance_score   × _importanceWeight
///
/// ▶ BGE-M3 向量化升级路径（阶段4.5+）：
///   1. 在 distillAllMemories 写入事实时，同步调用 BGE-M3 生成向量并存入
///      memory_facts.embedding BLOB 列（需 db version bump）
///   2. 将本文件中的 _computeRelevance() 替换为向量余弦相似度计算
///   3. recallByQuery() 的签名与返回格式无需变更，外部调用零修改
///
/// ⚠ 已知语义盲区（字符级算法固有限制，向量化可完全解决）：
///   · "猫今天不对劲" ≠ "用户对猫毛过敏"（字符无交集，语义相关）
///   · "肚子疼" ≠ "用户对花生过敏"（字符无交集，语义关联）
///   当前通过 _importanceWeight 兜底：高重要性事实即使无字符交集也有非零评分，
///   确保关键记忆始终保留进 top-K 候选。
class MemoryRecallService {
  // ── 评分权重 ────────────────────────────────────────────────────────────────
  /// 字符相关性权重（70%）
  static const double _relevanceWeight = 0.7;

  /// DB importance_score 权重（30%）
  /// 作用：当相关性为0时（短输入、纯表情等），确保高重要性事实仍有机会入选
  static const double _importanceWeight = 0.3;

  /// 默认召回条数上限
  static const int _defaultTopK = 3;

  /// 汉字字符集正则（CJK Unified Ideographs 基本区间 U+4E00~U+9FA5）
  static final RegExp _cjkRegex = RegExp(r'[一-龥]');

  // ── 公开接口 ────────────────────────────────────────────────────────────────

  /// 基于用户输入从本地 memory_facts 表召回最相关的记忆碎片内容
  ///
  /// [query]  当前用户输入原文（不做预处理，内部自行提取汉字字符集）
  /// [topK]   最多返回条数，默认3
  ///
  /// 返回：按综合评分降序排列的事实文本列表（空列表 = memory_facts 为空或全部失败）
  /// 失败降级：任何 DB 异常或解析错误均捕获并返回 []，不向上传播
  Future<List<String>> recallByQuery(
    String query, {
    int topK = _defaultTopK,
  }) async {
    try {
      final List<Map<String, dynamic>> allRows =
          await DbHelper.instance.getAllMemoryFacts();
      if (allRows.isEmpty) return [];

      // 提取查询字符集（去重后的汉字 Set）
      final Set<String> queryChars =
          _cjkRegex.allMatches(query).map((m) => m.group(0)!).toSet();

      final List<(double score, String content)> scored = [];

      for (final row in allRows) {
        final String content = row['fact_content'] as String? ?? '';
        if (content.isEmpty) continue;

        final double importance =
            (row['importance_score'] as num?)?.toDouble() ?? 0.5;

        // 综合评分 = 字符相关性 × 0.7 + 重要性 × 0.3
        final double relevance = _computeRelevance(queryChars, content);
        final double score =
            relevance * _relevanceWeight + importance * _importanceWeight;

        scored.add((score, content));
      }

      scored.sort((a, b) => b.$1.compareTo(a.$1));
      final List<String> results =
          scored.take(topK).map((e) => e.$2).toList();

      if (results.isNotEmpty) {
        debugPrint(
          'MemoryRecallService: 查询="${_truncate(query, 12)}" '
          '→ 召回${results.length}条: ${results.join(" | ")}',
        );
      }
      return results;
    } catch (e) {
      debugPrint('MemoryRecallService [召回失败，降级空列表]: $e');
      return [];
    }
  }

  // ── 内部：字符覆盖率相关性计算 ──────────────────────────────────────────────

  /// 计算用户输入字符集对事实内容的覆盖率
  ///
  /// 公式：|queryChars ∩ factChars| / |queryChars|
  ///
  /// 语义解读：
  ///   用户输入中有多大比例的字也出现在该事实文本中。
  ///   · "布丁生病了" vs "用户养了叫布丁的猫"
  ///     → queryChars={布,丁,生,病,了}, factChars={用,户,养,了,叫,布,丁,的,猫}
  ///     → intersection={布,丁,了}=3, coverage=3/5=0.6  ✓ 高相关
  ///   · "好累啊" vs "用户喜欢听R&B"
  ///     → intersection={}=0, coverage=0  ✓ 不相关
  ///
  /// ▶ BGE-M3升级替换点：
  ///   将此方法内部替换为 embedding(query) · embedding(fact) / (|q|·|f|)
  ///   即可实现语义级召回，外部签名不变。
  double _computeRelevance(Set<String> queryChars, String factContent) {
    if (queryChars.isEmpty) return 0.0;
    final Set<String> factChars =
        _cjkRegex.allMatches(factContent).map((m) => m.group(0)!).toSet();
    if (factChars.isEmpty) return 0.0;
    return queryChars.intersection(factChars).length / queryChars.length;
  }

  String _truncate(String s, int maxLen) =>
      s.length > maxLen ? '${s.substring(0, maxLen)}…' : s;
}
