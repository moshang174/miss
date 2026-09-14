import 'dart:convert';
import 'package:huainian/database/db_helper.dart';
import 'package:huainian/models/character_style.dart';
import 'package:huainian/services/style_extraction_service.dart';

/// 统一的角色配置领域模型，封装关系型数据与风格数据
class CharacterConfigEntity {
  final int id;
  final String name;
  final String personaPrompt;
  final String sleepStart;
  final String sleepEnd;
  final String analysisSource;
  final bool isInitialized;
  final CharacterStyle style; 

  CharacterConfigEntity({
    required this.id,
    required this.name,
    required this.personaPrompt,
    required this.sleepStart,
    required this.sleepEnd,
    required this.analysisSource,
    required this.isInitialized,
    required this.style,
  });

  factory CharacterConfigEntity.fromMap(Map<String, dynamic> map) {
    CharacterStyle parsedStyle;
    final styleJsonStr = map['style_json'] as String?;
    if (styleJsonStr != null && styleJsonStr.isNotEmpty) {
      try {
        final Map<String, dynamic> styleMap = jsonDecode(styleJsonStr);
        parsedStyle = CharacterStyle.fromJson(styleMap);
      } catch (_) {
        parsedStyle = CharacterStyle.fallback();
      }
    } else {
      parsedStyle = CharacterStyle.fallback();
    }

    return CharacterConfigEntity(
      id: map['id'] as int? ?? 1,
      name: map['name'] as String? ?? '未知伴侣',
      personaPrompt: map['persona_prompt'] as String? ?? '',
      sleepStart: map['sleep_start'] as String? ?? '23:00',
      sleepEnd: map['sleep_end'] as String? ?? '06:00',
      analysisSource: map['analysis_source'] as String? ?? '',
      isInitialized: (map['is_initialized'] as int? ?? 0) == 1,
      style: parsedStyle,
    );
  }
}

class CharacterRepository {
  final DbHelper _dbHelper = DbHelper.instance;

  /// 获取全局唯一角色的完整配置与风格特征（经过DB Seeder保护）
  Future<CharacterConfigEntity?> getCharacterConfig() async {
    // 通过 DbHelper 的 getCharacterConfig() 确保 Seeder 逻辑生效
    final map = await _dbHelper.getCharacterConfig();
    if (map == null) return null;
    return CharacterConfigEntity.fromMap(map);
  }

  /// 更新角色的名字、基础 Prompt 以及提取出的动态风格
  Future<int> updateCharacterStyle({
    required String name,
    required String basePrompt,
    required String sourcePath,
    required CharacterStyle newStyle,
  }) async {
    final db = await _dbHelper.database;
    final styleJsonStr = jsonEncode(newStyle.toJson());

    return await db.update(
      'character_config',
      {
        'name': name,
        'persona_prompt': basePrompt,
        'analysis_source': sourcePath,
        'is_initialized': 1,
        'style_json': styleJsonStr,
      },
      where: 'id = ?',
      whereArgs: [1],
    );
  }

  /// 将性格提取结果直接覆写进角色配置表（阶段3.5入口）
  Future<void> applyExtractionResult(ExtractionResult result, String sourcePath) async {
    await updateCharacterStyle(
      name: result.characterName,
      basePrompt: result.personaPrompt,
      sourcePath: sourcePath,
      newStyle: result.style,
    );
  }
}