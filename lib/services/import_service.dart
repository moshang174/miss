import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:gbk_codec/gbk_codec.dart';

/// 文本编码类型（V7.0 R2：自动检测）
enum _TextEncoding { utf8, gbk }

/// 聊天记录导入解析结果
///
/// [analysisSlice]  交给 LLM 分析的切片（小文件=全文；大文件=头/中/尾三段采样）
/// [fullText]       交叉核验语料（小文件=完整全文；大文件=采样合并文本，
///                  采样自原文，contains 核验语义不变，内存占用恒定）
/// [fileCount]      本次实际导入的文件数量
/// [totalChars]     合并后语料总字符数（大文件为估算值，供 UI 展示规模）
/// [isSampled]      是否触发了大文件采样（UI 可据此提示用户）
typedef ChatHistoryParseResult = ({
  String analysisSlice,
  String fullText,
  int fileCount,
  int totalChars,
  bool isSampled,
});

class ImportService {
  static const int _maxFileCount = 5;

  /// 总量安全阈值：200MB。流式读取内存恒定，该上限仅防御极端误选
  static const int _maxTotalBytes = 200 * 1024 * 1024;

  /// 小文件阈值：低于该值走一次性读取（保留完整全文供交叉核验）
  static const int _smallFileBytes = 2 * 1024 * 1024;

  /// 分析切片总预算（字符）：长上下文模型（kimi-k3 等）可轻松容纳，
  /// 覆盖更多对话轮次，性格提取更准
  static const int _maxAnalyzeChars = 12000;

  /// 单文件最小采样预算（字符）：多文件合并时均分总预算，保底每份文件
  /// 有足够语料暴露说话风格
  static const int _minSlicePerFile = 2000;

  /// 大文件采样配额：头部 20% / 中部 20% / 尾部 60%（尾部最新对话价值最高）
  static const double _headQuota = 0.2;
  static const double _midQuota = 0.2;

  /// 中部蓄水池采样行数上限（标准 reservoir sampling，每行等概率入选）
  static const int _midReservoirLines = 200;

  /// 唤起系统文件管理器，最多选取5份 .txt 聊天记录并合并解析。
  ///
  /// 读取策略：
  ///   - 小文件（≤2MB）：一次性读全量，行为与 V6.0 一致
  ///   - 大文件（>2MB）：流式逐行读取，内存恒定；头/中/尾三段采样
  ///
  /// 用户取消返回 null；发生错误直接抛异常。
  Future<ChatHistoryParseResult?> pickAndParseChatHistory() async {
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

      // 预扫描：过滤无效文件并统计总大小（先校验再读取，避免白读大文件）
      final List<String> paths = [];
      for (final pf in result.files) {
        final String? path = pf.path;
        if (path == null) {
          debugPrint('ImportService: 文件 ${pf.name} 无法取得本地路径，已跳过');
          continue;
        }
        paths.add(path);
      }

      return await parseFiles(paths);
    } catch (e) {
      debugPrint('ImportService [致命错误]: $e');
      rethrow;
    }
  }

  /// 解析指定路径的聊天记录文件（与文件选取解耦，可独立测试）
  ///
  /// 读取策略：
  ///   - 小文件（≤2MB）：一次性读全量，行为与 V6.0 一致
  ///   - 大文件（>2MB）：流式逐行读取，内存恒定；头/中/尾三段采样
  Future<ChatHistoryParseResult> parseFiles(List<String> paths) async {
    try {
      // 预扫描：过滤无效文件并统计总大小（先校验再读取，避免白读大文件）
      final List<File> validFiles = [];
      int totalBytes = 0;
      for (final path in paths) {
        final File file = File(path);
        if (!await file.exists()) {
          throw Exception('文件「$path」在沙盒中不存在，请重新选择');
        }
        totalBytes += await file.length();
        if (totalBytes > _maxTotalBytes) {
          throw Exception('文件总大小超出 200MB 安全阈值');
        }
        validFiles.add(file);
      }
      if (validFiles.isEmpty) {
        throw Exception('未能读取任何有效文件，请重新选择');
      }

      // 分析预算按文件数均分（含保底）
      final int perFileBudget = max(
        _maxAnalyzeChars ~/ validFiles.length,
        _minSlicePerFile,
      );

      final StringBuffer analysisMerged = StringBuffer();
      final StringBuffer validationMerged = StringBuffer();
      int totalChars = 0;
      bool anySampled = false;

      for (int i = 0; i < validFiles.length; i++) {
        final file = validFiles[i];
        final int fileBytes = await file.length();
        final bool isLarge = fileBytes > _smallFileBytes;

        final _FileReadResult r = isLarge
            ? await _readLargeFileSampled(file, perFileBudget)
            : await _readSmallFile(file, perFileBudget);

        if (r.slice.isEmpty) continue;
        anySampled = anySampled || r.isSampled;
        totalChars += r.totalChars;

        if (analysisMerged.isNotEmpty) {
          analysisMerged.write('\n\n');
          validationMerged.write('\n\n');
        }
        analysisMerged.write(r.slice);
        validationMerged.write(r.validationText);

        debugPrint(
          'ImportService: 文件${i + 1}(${_formatBytes(fileBytes)}) '
          '${isLarge ? "大文件流式采样" : "小文件全量"} → 切片 ${r.slice.length} 字符',
        );
      }

      final String analysisSlice = analysisMerged.toString().trim();
      if (analysisSlice.isEmpty) throw Exception('所选文件内容均为空');

      debugPrint(
        'ImportService: 成功合并 ${validFiles.length} 份文件，'
        '切片共 ${analysisSlice.length} 字符${anySampled ? "（含大文件采样）" : ""}',
      );

      return (
        analysisSlice: analysisSlice,
        fullText: validationMerged.toString().trim(),
        fileCount: validFiles.length,
        totalChars: totalChars,
        isSampled: anySampled,
      );
    } catch (e) {
      debugPrint('ImportService [致命错误]: $e');
      rethrow;
    }
  }

  // ── 小文件：一次性读取（V6.0 原行为，全文即切片、全文即核验语料）──────────────

  Future<_FileReadResult> _readSmallFile(File file, int budget) async {
    final List<int> bytes = await file.readAsBytes();
    final String content = _decodeBytes(bytes);
    // 换行归一化：防止 \r\n 与 \n 混杂导致 contains 核验失败
    final String fullText = _normalizeNewlines(content).trim();
    if (fullText.isEmpty) {
      return const _FileReadResult(slice: '', validationText: '', totalChars: 0, isSampled: false);
    }
    final String slice = _sampleByLines(fullText, budget);
    return _FileReadResult(
      slice: slice,
      validationText: fullText,
      totalChars: fullText.length,
      isSampled: slice.length < fullText.length,
    );
  }

  // ── 大文件：流式三段采样（内存占用恒定于采样预算，与文件大小无关）────────────
  //
  // 单遍扫描：
  //   头部段 —— 顺序写入直至满配额（交代人物关系与开场语境）
  //   中部段 —— 标准蓄水池采样（reservoir sampling），每行等概率入选，
  //             保留风格随时间的演变切片
  //   尾部段 —— 环形缓冲保留最新对话（风格提取价值最高）
  Future<_FileReadResult> _readLargeFileSampled(File file, int budget) async {
    final int headBudget = (budget * _headQuota).round();
    final int midBudget = (budget * _midQuota).round();
    final int tailBudget = budget - headBudget - midBudget; // 60%

    final StringBuffer head = StringBuffer();
    final List<String> midReservoir = [];
    int midReservoirChars = 0;
    int midCandidateCount = 0; // 参与蓄水池的行序号（1-based）
    final List<String> tailRing = [];
    int tailChars = 0;
    int totalCharsEstimate = 0;

    final Random random = Random();

    // V7.0 R2：先探测编码，GBK 走手动缓冲解码流（防双字节汉字被切块劈开）
    final encoding = await _detectEncoding(file);
    final Stream<String> lineStream = encoding == _TextEncoding.gbk
        ? _gbkChunkStream(file).transform(const LineSplitter())
        : file
            .openRead()
            // allowMalformed：大文件中混入少量坏字节时替换为 U+FFFD 继续扫描，
            // 而非整个流抛 FormatException 中断
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter());

    try {
      await for (final rawLine in lineStream) {
        final String line = rawLine.trim();
        totalCharsEstimate += rawLine.length + 1;
        if (line.isEmpty) continue;

        // 头部段：顺序填充
        if (head.length < headBudget) {
          head.writeln(line);
          continue;
        }

        // 尾部段：环形缓冲，超配额时弹出最旧行
        tailRing.add(line);
        tailChars += line.length + 1;
        while (tailChars > tailBudget && tailRing.isNotEmpty) {
          tailChars -= tailRing.removeAt(0).length + 1;
        }

        // 中部段：蓄水池采样（第 n 行以 K/n 概率替换随机槽位）
        midCandidateCount++;
        if (midReservoir.length < _midReservoirLines) {
          midReservoir.add(line);
          midReservoirChars += line.length + 1;
        } else {
          final int slot = random.nextInt(midCandidateCount);
          if (slot < _midReservoirLines) {
            midReservoirChars -= midReservoir[slot].length + 1;
            midReservoir[slot] = line;
            midReservoirChars += line.length + 1;
          }
        }
        // 中部字符预算防御：超长时丢弃最早条目
        while (midReservoirChars > midBudget && midReservoir.isNotEmpty) {
          midReservoirChars -= midReservoir.removeAt(0).length + 1;
        }
      }
    } catch (e) {
      debugPrint('ImportService [大文件流式读取中断]: $e（已保留扫描到的部分）');
    }

    final StringBuffer slice = StringBuffer();
    if (head.isNotEmpty) slice.write(head.toString());
    if (midReservoir.isNotEmpty) {
      if (slice.isNotEmpty) slice.writeln();
      slice.write(midReservoir.join('\n'));
    }
    if (tailRing.isNotEmpty) {
      if (slice.isNotEmpty) slice.writeln();
      slice.write(tailRing.join('\n'));
    }

    final String sliceText = slice.toString().trim();
    return _FileReadResult(
      slice: sliceText,
      validationText: sliceText, // 采样自原文，contains 核验语义不变
      totalChars: totalCharsEstimate,
      isSampled: true,
    );
  }

  // ── 编码检测与解码 ──────────────────────────────────────────────────────

  /// 编码自动检测：取文件头 8KB 做 UTF-8 严格解码，
  /// 失败则判定为 GBK（老版QQ/微信 Windows 导出记录的主流编码）。
  /// 注意：采样结尾可能切在多字节字符中间，需尾部裁剪 0~3 字节重试，
  /// 否则 UTF-8 文件会被误判为 GBK（UTF-8 单字符最长 4 字节）。
  /// 纯 ASCII 样本两种编码解码结果一致，判定为 UTF-8 无副作用。
  Future<_TextEncoding> _detectEncoding(File file) async {
    try {
      final raf = await file.open();
      final List<int> sample;
      try {
        sample = await raf.read(8192);
      } finally {
        await raf.close();
      }
      for (int trim = 0; trim <= 3; trim++) {
        try {
          utf8.decode(sample.sublist(0, sample.length - trim));
          return _TextEncoding.utf8;
        } on FormatException {
          continue;
        }
      }
      debugPrint('ImportService: 检测到非 UTF-8 编码，按 GBK 解码');
      return _TextEncoding.gbk;
    } catch (_) {
      return _TextEncoding.utf8;
    }
  }

  /// 字节流解码（小文件路径）：UTF-8 严格优先 → GBK → ASCII 兜底
  String _decodeBytes(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      try {
        return gbk_bytes.decode(bytes);
      } catch (_) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
  }

  /// GBK 大文件流式解码：openRead 按 64KB 切块，可能把双字节汉字
  /// 从中间劈开（首字节 0x81–0xFE）。手动缓冲：块尾若是 GBK 首字节，
  /// 保留至下一块拼合后再解码。
  Stream<String> _gbkChunkStream(File file) async* {
    final carry = <int>[];
    await for (final chunk in file.openRead()) {
      carry.addAll(chunk);
      int end = carry.length;
      if (end > 0 && carry[end - 1] >= 0x81 && carry[end - 1] <= 0xFE) {
        end--; // 块尾疑似半个汉字，留存
      }
      if (end == 0) continue;
      yield gbk_bytes.decode(carry.sublist(0, end));
      final rest = carry.sublist(end);
      carry
        ..clear()
        ..addAll(rest);
    }
    if (carry.isNotEmpty) {
      yield gbk_bytes.decode(carry);
    }
  }

  /// 换行归一化：统一为 \n，防止 \r\n 与 \n 混杂导致 contains 核验失败
  String _normalizeNewlines(String text) =>
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  /// 从文本末尾按完整行逆序采样，总字符数不超过 [maxChars]。
  /// 末尾是最新对话，LLM 分析价值最高；按完整行切分避免从行中间截断。
  String _sampleByLines(String text, int maxChars) {
    if (text.length <= maxChars) return text;

    final List<String> lines = text.split('\n');

    // 从末尾向前，找到能容纳的最大完整行集合的起始索引。
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }
}

/// 单文件读取结果（内部）
class _FileReadResult {
  final String slice;
  final String validationText;
  final int totalChars;
  final bool isSampled;

  const _FileReadResult({
    required this.slice,
    required this.validationText,
    required this.totalChars,
    required this.isSampled,
  });
}
