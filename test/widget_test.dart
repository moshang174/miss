// V6.0 单元测试：纯逻辑核心组件验证
// 覆盖：API 配置端点拼接 / 睡眠时段判定 / 记忆事实模型 / 角色风格约束生成
// V7.0 增补：免费通道配置判定 / 大文件流式采样导入

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:huainian/config/constants.dart';
import 'package:huainian/models/character_style.dart';
import 'package:huainian/services/chat_service.dart';
import 'package:huainian/services/import_service.dart';
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

  // V7.0 增补测试组
  v7Tests();
  v7R6Tests();
}


// ═══════════════════════ V7.0 R6 增补测试 ═══════════════════════

void v7R6Tests() {
  group('accumulateSseContent 流式响应累积（V7.0 R6）', () {
    String chunk(Map<String, dynamic> delta, {String finish = ''}) {
      final map = {
        'choices': [
          {
            'delta': delta,
            if (finish.isNotEmpty) 'finish_reason': finish,
          }
        ]
      };
      return 'data: ${jsonEncode(map)}\n\n';
    }

    test('常规流：多个 content 分片按序拼接', () {
      final raw = [
        chunk({'role': 'assistant'}),
        chunk({'content': '你好'}),
        chunk({'content': '呀'}),
        chunk({'content': '，哼哼~'}),
        chunk({}, finish: 'stop'),
        'data: [DONE]\n\n',
      ].join();
      expect(accumulateSseContent(raw), '你好呀，哼哼~');
    });

    test('推理分片（reasoning_content）被忽略，只累积可见内容', () {
      final raw = [
        chunk({'reasoning_content': '用户说了你好，我应该…'}),
        chunk({'reasoning_content': '回复要简短。'}),
        chunk({'content': '嗯'}),
        'data: [DONE]\n\n',
      ].join();
      expect(accumulateSseContent(raw), '嗯');
    });

    test('只有推理没有可见内容：返回空字符串（链路正常）', () {
      final raw = '${chunk({'reasoning_content': '思考中…'})}data: [DONE]\n\n';
      expect(accumulateSseContent(raw), '');
    });

    test('心跳注释与残缺行不中断解析', () {
      final raw = [
        ': keep-alive\n\n',
        chunk({'content': '第一'}),
        'data: {不完整的JSON\n\n',
        chunk({'content': '第二'}),
        'data: [DONE]\n\n',
      ].join();
      expect(accumulateSseContent(raw), '第一第二');
    });

    test('无任何有效数据块：返回 null（异常响应）', () {
      expect(accumulateSseContent(''), isNull);
      expect(accumulateSseContent(': 仅心跳\n\n'), isNull);
    });

    test('\\r\\n 行尾与 data: 后无空格均可解析', () {
      const raw = 'data:{"choices":[{"delta":{"content":"甲"}}]}\r\n\r\n'
          'data: {"choices":[{"delta":{"content":"乙"}}]}\r\n\r\n';
      expect(accumulateSseContent(raw), '甲乙');
    });
  });
}


// ═══════════════════════ V7.0 增补测试 ═══════════════════════

void v7Tests() {
  group('LlmApiConfig 接入方式（V7.0）', () {
    test('免费通道：空密钥仍视为已配置', () {
      const c = LlmApiConfig(
        baseUrl: AppConstants.freeApiBaseUrl,
        apiKey: '',
        model: AppConstants.freeModelName,
        provider: AppConstants.providerFree,
      );
      expect(c.isConfigured, isTrue);
      expect(c.isFreeChannel, isTrue);
    });

    test('高级通道：空密钥视为未配置', () {
      const c = LlmApiConfig(
        baseUrl: 'https://api.deepseek.com',
        apiKey: '',
        model: 'deepseek-chat',
        provider: AppConstants.providerCustom,
      );
      expect(c.isConfigured, isFalse);
      expect(c.isFreeChannel, isFalse);
    });

    test('高级通道：有密钥视为已配置', () {
      const c = LlmApiConfig(
        baseUrl: 'https://api.moonshot.cn/v1',
        apiKey: 'sk-test',
        model: 'kimi-k3',
        provider: AppConstants.providerCustom,
      );
      expect(c.isConfigured, isTrue);
    });
  });

  group('ImportService 大文件流式采样（V7.0）', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('huainian_import_test');
    });

    tearDown(() async {
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    Future<File> writeChatFile(String name, int lineCount) async {
      final file = File('${tmpDir.path}/$name');
      final sink = file.openWrite();
      for (int i = 0; i < lineCount; i++) {
        sink.writeln('Ta：这是第 $i 行对话内容，用于测试大文件流式采样功能。');
        sink.writeln('我：第 $i 行回复。');
      }
      await sink.flush();
      await sink.close();
      return file;
    }

    test('小文件：全文保留，不触发采样', () async {
      final file = await writeChatFile('small.txt', 20);
      final result = await ImportService().parseFiles([file.path]);
      expect(result.isSampled, isFalse);
      expect(result.analysisSlice.contains('第 0 行'), isTrue);
      expect(result.analysisSlice.contains('第 19 行'), isTrue);
      // 内容未超预算时 切片 == 全文
      expect(result.fullText.length,
          greaterThanOrEqualTo(result.analysisSlice.length));
    });

    test('大文件：触发采样且头部/尾部均被覆盖', () async {
      // 6 万对 ≈ 12 万行 ≈ 7MB，超过 2MB 小文件阈值
      final file = await writeChatFile('large.txt', 60000);
      final fileSize = await file.length();
      expect(fileSize, greaterThan(2 * 1024 * 1024));

      final stopwatch = Stopwatch()..start();
      final result = await ImportService().parseFiles([file.path]);
      stopwatch.stop();

      expect(result.isSampled, isTrue);
      // 切片受预算约束（12000 字符 + 少量余量）
      expect(result.analysisSlice.length, lessThanOrEqualTo(13000));
      // 头部采样覆盖最早对话
      expect(result.analysisSlice.contains('第 0 行'), isTrue);
      // 尾部采样（60% 配额）覆盖最新对话
      expect(result.analysisSlice.contains('第 59999 行'), isTrue);
      // 总字符数为全文件估算，远大于切片
      expect(result.totalChars, greaterThan(result.analysisSlice.length));
      debugPrint('大文件流式采样耗时: ${stopwatch.elapsedMilliseconds}ms');
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('不存在的文件：抛出友好异常', () async {
      expect(
        () => ImportService().parseFiles(['${tmpDir.path}/ghost.txt']),
        throwsA(isA<Exception>()),
      );
    });

    test('GBK 编码小文件：正确解码不乱码', () async {
      final file = File('${tmpDir.path}/gbk_small.txt');
      final gbkBytes = gbk_bytes.encode('Ta：哼哼~\n我：你去死！\nTa：莫西莫西');
      await file.writeAsBytes(gbkBytes);
      final result = await ImportService().parseFiles([file.path]);
      expect(result.analysisSlice.contains('哼哼~'), isTrue);
      expect(result.analysisSlice.contains('莫西莫西'), isTrue);
      expect(result.analysisSlice.contains('�'), isFalse);
    });

    test('GBK 编码大文件：流式解码且跨块汉字不碎裂', () async {
      final file = File('${tmpDir.path}/gbk_large.txt');
      final sink = file.openWrite();
      // 6 万对行，GBK 编码后约 5MB，超过小文件阈值
      for (int i = 0; i < 60000; i++) {
        sink.add(gbk_bytes.encode('Ta：这是第 $i 行对话内容，用于测试GBK流式解码。'));
        sink.add(const [10]);
      }
      await sink.flush();
      await sink.close();
      expect(await file.length(), greaterThan(2 * 1024 * 1024));

      final result = await ImportService().parseFiles([file.path]);
      expect(result.isSampled, isTrue);
      expect(result.analysisSlice.contains('第 0 行'), isTrue);
      expect(result.analysisSlice.contains('第 59999 行'), isTrue);
      // 跨块汉字不碎裂的标志：无替换字符
      expect(result.analysisSlice.contains('�'), isFalse);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
