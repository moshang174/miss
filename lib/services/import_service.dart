import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';

class ImportService {
  static const int _maxFileCount = 5;
  static const int _maxTotalBytes = 20 * 1024 * 1024; // 20 MB
  static const int _maxAnalyzeChars = 2000;

  /// 唤起系统文件管理器，最多选取5份 .txt 聊天记录并合并解析。
  /// 返回值：(analysisSlice, fullText, fileCount)
  ///   - analysisSlice：交给 LLM 分析的末尾切片（≤2000字符）
  ///   - fullText：完整合并文本（用于原文交叉核验）
  ///   - fileCount：本次实际导入的文件数量
  /// 用户取消返回 null；发生错误直接抛异常。
  Future<({String analysisSlice, String fullText, int fileCount})?> pickAndParseChatHistory() async {
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt'],
        allowMultiple: true,
      );

      if (result == null || result.files.isEmpty) {
        debugPrint('ImportService: 用户取消了文件选择');
        return null;
      }

      // 文件数量上限防御
      if (result.files.length > _maxFileCount) {
        throw Exception(
          '最多同时导入 $_maxFileCount 份聊天记录，当前选择了 ${result.files.length} 份',
        );
      }

      // 逐文件读取并合并
      final StringBuffer merged = StringBuffer();
      int totalBytes = 0;

      for (final pf in result.files) {
        final String? path = pf.path;
        if (path == null) {
          debugPrint('ImportService: 文件 ${pf.name} 无法取得本地路径，已跳过');
          continue;
        }

        final File file = File(path);
        if (!await file.exists()) {
          throw Exception('文件「${pf.name}」在沙盒中不存在，请重新选择');
        }

        totalBytes += await file.length();
        if (totalBytes > _maxTotalBytes) {
          throw Exception('文件总大小超出 20MB 安全阈值');
        }

        final List<int> bytes = await file.readAsBytes();
        String content;
        try {
          content = utf8.decode(bytes, allowMalformed: true);
        } catch (_) {
          content = ascii.decode(bytes, allowInvalid: true);
        }

        // 换行归一化：统一为 \n，防止 \r\n 与 \n 混杂导致 contains 核验失败
        final String trimmed = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
        if (trimmed.isNotEmpty) {
          if (merged.isNotEmpty) merged.write('\n\n');
          merged.write(trimmed);
        }
      }

      final String fullText = merged.toString().trim();
      if (fullText.isEmpty) throw Exception('所选文件内容均为空');

      final String analysisSlice = _sampleByLines(fullText, _maxAnalyzeChars);
      final int fileCount = result.files.length;

      debugPrint('ImportService: 成功合并 $fileCount 份文件，共 ${fullText.length} 字符');
      return (analysisSlice: analysisSlice, fullText: fullText, fileCount: fileCount);

    } catch (e) {
      debugPrint('ImportService [致命错误]: $e');
      rethrow;
    }
  }

  /// 从文本末尾按完整行逆序采样，总字符数不超过 [maxChars]。
  /// 末尾是最新对话，LLM 分析价值最高；按完整行切分避免从行中间截断。
  String _sampleByLines(String text, int maxChars) {
    if (text.length <= maxChars) return text;

    final List<String> lines = text.split('\n');

    // 从末尾向前，找到能容纳的最大完整行集合的起始索引。
    // startIdx 始终指向"还未确定能否纳入"的行，循环结束后
    // lines.sublist(startIdx) 即为刚好不超出 maxChars 的子集。
    int startIdx = lines.length; // 初始：不包含任何行
    int accumulated = 0;

    while (startIdx > 0) {
      final int needed = lines[startIdx - 1].length + 1; // +1 for '\n'
      if (accumulated + needed > maxChars) break;
      accumulated += needed;
      startIdx--; // 该行可以纳入，上移起点
    }

    // 兜底：若单行超长（没有任何完整行能纳入），直接截取末尾字符
    if (startIdx == lines.length) {
      return text.substring(text.length - maxChars).trim();
    }

    return lines.sublist(startIdx).join('\n').trim();
  }
}
