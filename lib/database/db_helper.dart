import 'dart:async';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:huainian/services/memory_distillation_service.dart';

class DbHelper {
  static final DbHelper instance = DbHelper._init();
  static Database? _database;

  DbHelper._init();

  // 当前数据库版本提升至 3 (V6.0：新增 app_settings 配置表)
  static const int _dbVersion = 3;
  // 数据库文件名保持旧名不变：改名会导致老用户升级后数据库被孤立、数据全丢
  static const String _dbName = 'yiciyuan_communication.db';

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB(_dbName);
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  /// V1.1 基础建表逻辑，同时兼容 V1.2 的全新字段结构 (明确指定 Future<void> 消除警告)
  Future<void> _createDB(Database db, int version) async {
    // 1. character_config 表
    await db.execute('''
      CREATE TABLE character_config (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        persona_prompt TEXT,
        sleep_start TEXT DEFAULT '23:00',
        sleep_end TEXT DEFAULT '06:00',
        analysis_source TEXT,
        is_initialized INTEGER DEFAULT 0,
        style_json TEXT 
      )
    ''');

    // 2. conversations 回忆录流水表
    await db.execute('''
      CREATE TABLE conversations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        emotion_tag TEXT
      )
    ''');

    // 3. memory_facts 深层记忆提取表
    await db.execute('''
      CREATE TABLE memory_facts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        fact_type TEXT NOT NULL,
        fact_content TEXT NOT NULL,
        source_message_id INTEGER,
        importance_score REAL
      )
    ''');

    // 4. scheduled_messages 主动陪伴触发器
    await db.execute('''
      CREATE TABLE scheduled_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scheduled_time TEXT NOT NULL,
        content_draft TEXT NOT NULL,
        is_sent INTEGER DEFAULT 0
      )
    ''');

    // 5. app_settings 应用配置表（V6.0 新增：API 配置等键值对）
    await db.execute('''
      CREATE TABLE app_settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');

    // 插入默认兜底数据
    await db.insert('character_config', {
      'id': 1,
      'name': '未知伴侣',
      'persona_prompt': '',
      'analysis_source': '',
      'is_initialized': 0,
      'style_json': '{}'
    });
  }

  /// 核心数据库迁移逻辑：处理从旧版本无损升级 (明确指定 Future<void> 消除警告)
  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE character_config ADD COLUMN style_json TEXT;');
      await db.update(
        'character_config',
        {'style_json': '{}'},
        where: 'id = ?',
        whereArgs: [1],
      );
    }
    if (oldVersion < 3) {
      // V6.0：新增 app_settings 配置表（API 配置等键值对存储）
      await db.execute('''
        CREATE TABLE IF NOT EXISTS app_settings (
          key TEXT PRIMARY KEY,
          value TEXT
        )
      ''');
    }
  }

  // =========================================================================
  // 以下为完美兼容 lib/main.dart 调用的核心数据库操作方法
  // =========================================================================

  /// 获取当前唯一的角色配置原始 Map
  /// 只读不写：不对数据库做任何修改，消除与导入流程的竞态风险。
  Future<Map<String, dynamic>?> getCharacterConfig() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'character_config',
      where: 'id = ?',
      whereArgs: [1],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return maps.first;
  }

  /// 获取历史消息记录（按主键id升序，保证插入顺序）
  Future<List<Map<String, dynamic>>> getAllMessages() async {
    final db = await database;
    return await db.query('conversations', orderBy: 'id ASC');
  }

  /// 读取最近 [limit] 条对话记录（按 id 升序，保持对话时间线顺序）
  /// 先按 id DESC 取最后 N 条，再反转为时间正序供 UI 渲染
  Future<List<Map<String, dynamic>>> getRecentMessages({int limit = 80}) async {
    if (limit <= 0) return [];
    final db = await database;
    final rows = await db.query(
      'conversations',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.reversed.toList();
  }

  /// 完美契合 main.dart 传入的双参数格式
  Future<int> insertMessage(String role, String content) async {
    final db = await database;
    return await db.insert('conversations', {
      'role': role,
      'content': content,
      'timestamp': DateTime.now().toString(),
      'emotion_tag': '正常',
    });
  }

  /// 清空数据库连接与回忆录流水 (明确指定 Future<void> 消除警告)
  Future<void> clearDatabase() async {
    final db = await database;
    await db.delete('conversations');
    await db.update(
      'character_config',
      {
        'name': '未知伴侣',
        'persona_prompt': '',
        'analysis_source': '',
        'is_initialized': 0,
        'style_json': '{}'
      },
      where: 'id = ?',
      whereArgs: [1],
    );
  }

  // =========================================================================
  // memory_facts 长期记忆 CRUD
  // =========================================================================

  /// 写入单条事实碎片
  Future<int> insertMemoryFact(MemoryFact fact) async {
    final db = await database;
    return await db.insert('memory_facts', {
      'fact_type': fact.factType,
      'fact_content': fact.factContent,
      'source_message_id': fact.sourceMessageId,
      'importance_score': fact.importanceScore,
    });
  }

  /// 读取全部事实碎片，按重要性降序排列
  Future<List<Map<String, dynamic>>> getAllMemoryFacts() async {
    final db = await database;
    return await db.query(
      'memory_facts',
      orderBy: 'importance_score DESC',
    );
  }

  /// 清空全部事实碎片（覆盖式重提炼前调用）
  Future<void> clearMemoryFacts() async {
    final db = await database;
    await db.delete('memory_facts');
  }

  // =========================================================================
  // scheduled_messages 主动消息调度 CRUD（阶段三 F-013/F-015）
  // =========================================================================

  /// 写入一条主动消息调度记录
  Future<int> insertScheduledMessage(
      String scheduledTime, String contentDraft) async {
    final db = await database;
    return await db.insert('scheduled_messages', {
      'scheduled_time': scheduledTime,
      'content_draft': contentDraft,
      'is_sent': 0,
    });
  }

  /// 查询今日已生成的主动消息数量（用于限制每日上限）
  /// 使用 ISO-8601 日期前缀匹配：YYYY-MM-DD
  Future<int> getTodayScheduledCount() async {
    final db = await database;
    final today = DateTime.now();
    final datePrefix =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM scheduled_messages WHERE scheduled_time LIKE ?',
      ['$datePrefix%'],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  /// 读取所有未发送的主动消息（前台展示时消费）
  Future<List<Map<String, dynamic>>> getUnsentScheduledMessages() async {
    final db = await database;
    return await db.query(
      'scheduled_messages',
      where: 'is_sent = ?',
      whereArgs: [0],
      orderBy: 'id ASC',
    );
  }

  /// 将指定主动消息标记为已发送
  Future<void> markScheduledMessageSent(int id) async {
    final db = await database;
    await db.update(
      'scheduled_messages',
      {'is_sent': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // =========================================================================
  // app_settings 配置读写（V6.0 新增）
  // =========================================================================

  /// 读取单个配置项，不存在返回 null
  Future<String?> getSetting(String key) async {
    final db = await database;
    final maps = await db.query(
      'app_settings',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return maps.first['value'] as String?;
  }

  /// 写入/更新配置项
  Future<void> setSetting(String key, String value) async {
    final db = await database;
    await db.insert(
      'app_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 彻底修复此处 Future<void> 语法错误，消除全部 Undefined class 'Future' 级联报错
  Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
    }
  }
}