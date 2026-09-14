// V6.0 单元测试：纯逻辑核心组件验证
// 覆盖：API 配置端点拼接 / 睡眠时段判定 / 记忆事实模型 / 角色风格约束生成

import 'package:flutter_test/flutter_test.dart';
import 'package:huainian/models/character_style.dart';
import 'package:huainian/services/chat_service.dart';
import 'package:huainian/services/llm_api_service.dart';
import 'package:huainian/services/memory_distillation_service.dart';

void main() {
  group('LlmApiConfig.chatCompletionsUrl 端点拼接', () {
    LlmApiConfig config(String baseUrl) =>
        LlmApiConfig(baseUrl: baseUrl, apiKey: 'k', model: 'm');

    test('裸域名自动补全路径', () {
      expect(config('https://api.deepseek.com').chatCompletionsUrl,
          'https://api.deepseek.com/chat/completions');
    });

    test('末尾斜杠被清理', () {
      expect(config('https://api.deepseek.com/').chatCompletionsUrl,
          'https://api.deepseek.com/chat/completions');
    });

    test('带 /v1 前缀保留', () {
      expect(config('https://api.example.com/v1').chatCompletionsUrl,
          'https://api.example.com/v1/chat/completions');
    });

    test('已含完整路径不重复追加', () {
      expect(
          config('https://api.example.com/v1/chat/completions')
              .chatCompletionsUrl,
          'https://api.example.com/v1/chat/completions');
    });

    test('首尾空白被忽略', () {
      expect(config('  https://api.deepseek.com  ').chatCompletionsUrl,
          'https://api.deepseek.com/chat/completions');
    });

    test('空密钥视为未配置', () {
      expect(const LlmApiConfig(baseUrl: 'https://a.com', apiKey: ' ', model: 'm')
          .isConfigured, isFalse);
      expect(const LlmApiConfig(baseUrl: 'https://a.com', apiKey: 'sk-x', model: 'm')
          .isConfigured, isTrue);
    });
  });

  group('ChatService.isInSleepRange 睡眠时段判定', () {
    test('跨午夜：23:00-06:00 与当前时间比对一致', () {
      final now = DateTime.now();
      final expected = now.hour >= 23 || now.hour < 6;
      expect(ChatService.isInSleepRange('23:00', '06:00'), expected);
    });

    test('同日时段：以当前时间为中点的区间必为 true', () {
      final now = DateTime.now();
      final start = now.subtract(const Duration(hours: 1));
      final end = now.add(const Duration(hours: 1));
      String fmt(DateTime t) =>
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      // 处理跨天边界：仅在同日区间语义下断言
      if (start.day == now.day && end.day == now.day) {
        expect(ChatService.isInSleepRange(fmt(start), fmt(end)), isTrue);
      }
    });

    test('非法输入安全降级为 false（不休眠）', () {
      expect(ChatService.isInSleepRange('abc', 'def'), isFalse);
      expect(ChatService.isInSleepRange('', ''), isFalse);
      expect(ChatService.isInSleepRange('25:99', '26:99'), isFalse);
    });
  });

  group('MemoryFact.fromJson 事实模型', () {
    test('importance_score 越界值被 clamp 到 0~1', () {
      final over = MemoryFact.fromJson(
          {'fact_type': 'habit', 'fact_content': 'x', 'importance_score': 1.5});
      final under = MemoryFact.fromJson(
          {'fact_type': 'habit', 'fact_content': 'x', 'importance_score': -0.3});
      expect(over.importanceScore, 1.0);
      expect(under.importanceScore, 0.0);
    });

    test('缺省字段安全回落', () {
      final fact = MemoryFact.fromJson(const {});
      expect(fact.factType, 'other');
      expect(fact.factContent, '');
      expect(fact.importanceScore, 0.5);
    });
  });

  group('CharacterStyle 风格约束生成', () {
    test('toPromptConstraints 包含字数与符号约束文本', () {
      const style = CharacterStyle(
        avgLength: 8,
        maxLength: 15,
        allowedSymbols: ['~'],
        modalParticles: ['哼哼'],
        toneGuide: ['你去死！'],
      );
      final text = style.toPromptConstraints();
      expect(text, contains('8'));
      expect(text, contains('15'));
      expect(text, contains('~'));
      expect(text, contains('哼哼'));
      expect(text, contains('你去死！'));
    });

    test('JSON 序列化往返一致', () {
      const style = CharacterStyle(
        avgLength: 10,
        maxLength: 20,
        allowedSymbols: ['(ー_ー)'],
        modalParticles: ['哼'],
        toneGuide: ['少来'],
      );
      final restored = CharacterStyle.fromJson(style.toJson());
      expect(restored.avgLength, 10);
      expect(restored.maxLength, 20);
      expect(restored.allowedSymbols, ['(ー_ー)']);
      expect(restored.modalParticles, ['哼']);
      expect(restored.toneGuide, ['少来']);
    });

    test('fallback 兜底值合法', () {
      final fb = CharacterStyle.fallback();
      expect(fb.avgLength, greaterThan(0));
      expect(fb.maxLength, greaterThanOrEqualTo(fb.avgLength));
    });
  });
}
