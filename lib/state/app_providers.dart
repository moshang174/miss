import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huainian/repositories/character_repository.dart';
import 'package:huainian/services/import_service.dart';
import 'package:huainian/services/llm_api_service.dart';
import 'package:huainian/services/memory_distillation_service.dart';
import 'package:huainian/services/memory_recall_service.dart';
import 'package:huainian/services/style_extraction_service.dart';

// ==========================================
// 服务层 Provider
// ==========================================

final llmApiServiceProvider = Provider<LlmApiService>((ref) => LlmApiService());

final importServiceProvider = Provider<ImportService>((ref) => ImportService());
final styleExtractionServiceProvider =
    Provider<StyleExtractionService>((ref) => StyleExtractionService());
final characterRepositoryProvider =
    Provider<CharacterRepository>((ref) => CharacterRepository());
final memoryDistillationServiceProvider =
    Provider<MemoryDistillationService>((ref) => MemoryDistillationService());
final memoryRecallServiceProvider =
    Provider<MemoryRecallService>((ref) => MemoryRecallService());

// ==========================================
// 导入 + 性格提取流水线状态层
// ==========================================

enum ImportPhase { idle, pickingFile, extractingStyle, done, error }

class ImportState {
  final ImportPhase phase;
  final String previewText;
  final String? validSlice;
  final ExtractionResult? extractionResult;

  const ImportState({
    required this.phase,
    required this.previewText,
    this.validSlice,
    this.extractionResult,
  });

  bool get isLoading =>
      phase == ImportPhase.pickingFile || phase == ImportPhase.extractingStyle;

  static const idle = ImportState(
    phase: ImportPhase.idle,
    previewText: '暂未导入任何聊天记录',
  );

  ImportState copyWith({
    ImportPhase? phase,
    String? previewText,
    String? validSlice,
    ExtractionResult? extractionResult,
  }) {
    return ImportState(
      phase: phase ?? this.phase,
      previewText: previewText ?? this.previewText,
      validSlice: validSlice ?? this.validSlice,
      extractionResult: extractionResult ?? this.extractionResult,
    );
  }
}

class ImportNotifier extends StateNotifier<ImportState> {
  final ImportService _importService;
  final StyleExtractionService _extractionService;
  final CharacterRepository _repository;

  ImportNotifier(this._importService, this._extractionService, this._repository)
      : super(ImportState.idle);

  Future<void> triggerImport() async {
    state = const ImportState(
      phase: ImportPhase.pickingFile,
      previewText: '正在唤起系统文件管理器...',
    );

    ({String analysisSlice, String fullText, int fileCount})? parsed;
    try {
      parsed = await _importService.pickAndParseChatHistory();
    } catch (e) {
      state = ImportState(
        phase: ImportPhase.error,
        previewText: '【导入失败】: ${e.toString().replaceAll('Exception: ', '')}',
      );
      return;
    }

    if (parsed == null) {
      state = ImportState.idle.copyWith(previewText: '导入已取消');
      return;
    }

    final int fileCount = parsed.fileCount;
    final String fileCountHint = fileCount == 1
        ? '文件读取成功'
        : '$fileCount 份文件已合并';

    state = ImportState(
      phase: ImportPhase.extractingStyle,
      previewText: '【$fileCountHint】正在分析 Ta 的说话方式...\n\n'
          '(大模型思考需要时间，预计等待 1~4 分钟，请勿关闭应用)',
      validSlice: parsed.analysisSlice,
    );

    try {
      final ExtractionResult result = await _extractionService.extractStyle(
        parsed.analysisSlice,
        fullText: parsed.fullText,
      );
      await _repository.applyExtractionResult(result, '用户导入聊天记录');
      state = ImportState(
        phase: ImportPhase.done,
        previewText: _buildSuccessSummary(result, fileCount),
        validSlice: parsed.analysisSlice,
        extractionResult: result,
      );
    } catch (e) {
      state = ImportState(
        phase: ImportPhase.error,
        previewText: '【性格提取失败】: ${e.toString().replaceAll('Exception: ', '')}\n\n'
            '提示：请检查通讯设置中的连接配置是否正确，并确认网络可用。',
        validSlice: parsed.analysisSlice,
      );
    }
  }

  static String _buildSuccessSummary(ExtractionResult r, int fileCount) {
    final symbols = r.style.allowedSymbols.isEmpty ? '无' : r.style.allowedSymbols.join(' ');
    final particles =
        r.style.modalParticles.isEmpty ? '无' : r.style.modalParticles.join('、');
    final toneText = r.style.toneGuide.isEmpty
        ? '无'
        : r.style.toneGuide.map((t) => '"$t"').join('  ');
    final fileInfo = fileCount == 1 ? '' : '（已合并 $fileCount 份文件）\n';

    return '【连接建立成功】角色已生效，立即可对话\n\n'
        '━━━━━━━━━━ 提取摘要 ━━━━━━━━━━\n'
        '称呼：${r.characterName}  $fileInfo'
        '字数上限：${r.style.maxLength} 字（均值 ${r.style.avgLength} 字）\n'
        '专属符号：$symbols\n'
        '口头禅：$particles\n'
        '特征表达：$toneText\n\n'
        '人格设定：\n${r.personaPrompt}';
  }
}

final importStateProvider =
    StateNotifierProvider<ImportNotifier, ImportState>((ref) {
  return ImportNotifier(
    ref.read(importServiceProvider),
    ref.read(styleExtractionServiceProvider),
    ref.read(characterRepositoryProvider),
  );
});

// ==========================================
// 阶段4.0：记忆提纯状态层
// ==========================================

enum DistillationPhase { idle, running, done, error }

class DistillationState {
  final DistillationPhase phase;
  final String statusText;
  final int totalBatches;
  final int completedBatches;
  final int factsFound;

  const DistillationState({
    required this.phase,
    required this.statusText,
    this.totalBatches = 0,
    this.completedBatches = 0,
    this.factsFound = 0,
  });

  bool get isRunning => phase == DistillationPhase.running;

  static const idle = DistillationState(
    phase: DistillationPhase.idle,
    statusText: '尚未提炼，点击按钮开始提炼长期记忆',
  );
}

class DistillationNotifier extends StateNotifier<DistillationState> {
  final MemoryDistillationService _service;

  DistillationNotifier(this._service) : super(DistillationState.idle);

  Future<void> startDistillation() async {
    state = const DistillationState(
      phase: DistillationPhase.running,
      statusText: '正在翻阅回忆录，整理共同的记忆...',
    );

    try {
      final totalFacts = await _service.distillAllMemories(
        onProgress: ({
          required int totalBatches,
          required int completedBatches,
          required int factsFound,
        }) {
          if (!mounted) return;
          final isFinished = completedBatches >= totalBatches && totalBatches > 0;
          state = DistillationState(
            phase: isFinished ? DistillationPhase.done : DistillationPhase.running,
            statusText: isFinished
                ? '【提炼完成】共写入 $factsFound 条记忆碎片'
                : '分析中：批次 $completedBatches/$totalBatches，已提炼 $factsFound 条',
            totalBatches: totalBatches,
            completedBatches: completedBatches,
            factsFound: factsFound,
          );
        },
      );

      if (state.phase == DistillationPhase.running) {
        state = DistillationState(
          phase: DistillationPhase.done,
          statusText: '【提炼完成】共写入 $totalFacts 条记忆碎片',
          factsFound: totalFacts,
        );
      }
    } catch (e) {
      state = DistillationState(
        phase: DistillationPhase.error,
        statusText: '【提炼失败】: ${e.toString().replaceAll('Exception: ', '')}\n'
            '请检查通讯设置中的连接配置，并确认回忆录中有对话记录。',
      );
    }
  }
}

final distillationStateProvider =
    StateNotifierProvider<DistillationNotifier, DistillationState>((ref) {
  return DistillationNotifier(ref.read(memoryDistillationServiceProvider));
});
