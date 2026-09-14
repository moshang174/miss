import 'package:flutter/foundation.dart';

@immutable
class CharacterStyle {
  final int avgLength;
  final int maxLength;
  final List<String> allowedSymbols;
  final List<String> modalParticles;

  /// 从聊天记录中提炼的3-5条特征句式/惯用表达，直接来自原文
  /// 例如：["哼哼~", "好啦好啦", "你去死！", "等等我哈"]
  final List<String> toneGuide;

  const CharacterStyle({
    required this.avgLength,
    required this.maxLength,
    required this.allowedSymbols,
    required this.modalParticles,
    this.toneGuide = const [],
  });

  factory CharacterStyle.fallback() {
    return const CharacterStyle(
      avgLength: 10,
      maxLength: 20,
      allowedSymbols: [],
      modalParticles: [],
      toneGuide: [],
    );
  }

  factory CharacterStyle.fromJson(Map<String, dynamic> json) {
    return CharacterStyle(
      avgLength: json['avg_length'] as int? ?? 10,
      maxLength: json['max_length'] as int? ?? 20,
      allowedSymbols: List<String>.from(json['allowed_symbols'] as List? ?? []),
      modalParticles: List<String>.from(json['modal_particles'] as List? ?? []),
      toneGuide: List<String>.from(json['tone_guide'] as List? ?? []),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'avg_length': avgLength,
      'max_length': maxLength,
      'allowed_symbols': allowedSymbols,
      'modal_particles': modalParticles,
      'tone_guide': toneGuide,
    };
  }

  String toPromptConstraints() {
    final symbolsText =
        allowedSymbols.isEmpty ? '不使用特殊符号' : allowedSymbols.join('、');
    final particlesText =
        modalParticles.isEmpty ? '无特定口头禅' : modalParticles.join('、');

    final toneSection = toneGuide.isEmpty
        ? ''
        : '\n【特征说话方式】: 以下是Ta的惯用表达，请在自然合适时融入，不可逐字照搬但风格须一致: [${toneGuide.join('、')}]。';

    return '''
【句式长度约束】: 倾向于简短直接，平均每次回复控制在 $avgLength 字左右，绝对不可超过 $maxLength 字。
【习惯特殊符号】: 句尾或合适位置只能自然使用: [$symbolsText]。严禁使用此范围外的任何符号。
【高频口头禅/语气词】: 在对话中自然融入以下表达: [$particlesText]。$toneSection
''';
  }
}
