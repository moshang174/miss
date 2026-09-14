import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:huainian/database/db_helper.dart';
import 'package:huainian/services/chat_service.dart';

/// 阶段三（F-013/F-014）：主动消息生成与本地推送服务
///
/// 架构说明：
/// - backgroundCheck() 由 workmanager 后台任务调用（隔离执行）
/// - 每次调用有约 33% 概率真正生成消息，对应每日 3 条的目标频次（2h/次×8次×33%≈3条）
/// - 通知发送走 flutter_local_notifications，不依赖自建服务器
///
/// V6.0 说明：
/// - 消息生成改经 ChatService → LlmApiService（云端 API），需设备联网
/// - API 密钥未配置时生成会失败并安全跳过，不会产生脏数据
class ProactiveMessageService {
  static const int _maxMessagesPerDay = 3;
  static const double _triggerProbability = 0.33;
  static const String _notificationChannelId = 'proactive_channel';
  static const String _notificationChannelName = '来自TA的消息';

  /// workmanager 后台任务入口（@pragma 标注在 main.dart 顶层函数中）
  ///
  /// 在后台隔离中重新初始化所有 Flutter 插件环境，然后：
  /// 1. 检查睡眠时段 → 直接返回
  /// 2. 检查每日发送上限 → 直接返回
  /// 3. 随机概率门控
  /// 4. 调用 ChatService 生成消息
  /// 5. 写入 scheduled_messages 表
  /// 6. 发送本地通知
  static Future<void> backgroundCheck() async {
    final plugin = FlutterLocalNotificationsPlugin();

    // 后台隔离中必须重新初始化通知插件
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await plugin.initialize(initSettings);

    // 1. 读取角色配置
    final config = await DbHelper.instance.getCharacterConfig();
    if (config == null) {
      debugPrint('ProactiveMessageService [后台]: 未读到角色配置，跳过');
      return;
    }

    final sleepStart = config['sleep_start'] as String? ?? '23:00';
    final sleepEnd = config['sleep_end'] as String? ?? '06:00';
    final characterName = config['name'] as String? ?? 'TA';
    final personaPrompt = config['persona_prompt'] as String? ?? '';

    // 2. 睡眠时段检测：23:00-06:00 不主动发送
    if (ChatService.isInSleepRange(sleepStart, sleepEnd)) {
      debugPrint('ProactiveMessageService [后台]: 当前处于休眠时段，跳过');
      return;
    }

    // 3. 每日上限检测
    final todayCount = await DbHelper.instance.getTodayScheduledCount();
    if (todayCount >= _maxMessagesPerDay) {
      debugPrint('ProactiveMessageService [后台]: 今日消息数已达上限 ($todayCount/$_maxMessagesPerDay)，跳过');
      return;
    }

    // 4. 随机概率门控：2h触发一次×8次×33%≈3条/天
    if (Random().nextDouble() > _triggerProbability) {
      debugPrint('ProactiveMessageService [后台]: 本次随机未命中，跳过');
      return;
    }

    // 5. 生成主动消息内容（调用大模型 API）
    final now = DateTime.now();
    final timeStr =
        '${now.hour}:${now.minute.toString().padLeft(2, '0')}';
    final service = ChatService();
    final String? draft;
    try {
      final raw = await service.sendChatMessage([
        {
          'role': 'system',
          'content':
              '$personaPrompt\n现在是$timeStr，你主动给朋友发一条消息。'
              '直接说你想说的话（分享一件事、一个感受、或随手一句），'
              '不要打招呼问"在吗"，不加任何解释，就像真实朋友随手发来的。',
        },
        {
          'role': 'user',
          'content': '（你突然想到了一件事或者有点无聊，随手发来一条消息）',
        },
      ]);
      draft = (raw.isEmpty || raw.startsWith('错误：') || raw.startsWith('异常：'))
          ? null
          : raw;
    } catch (e) {
      debugPrint('ProactiveMessageService [后台]: 消息生成异常: $e');
      return;
    } finally {
      service.dispose();
    }

    if (draft == null) {
      debugPrint('ProactiveMessageService [后台]: 生成结果无效，跳过');
      return;
    }

    // 6. 写入 scheduled_messages 表
    await DbHelper.instance.insertScheduledMessage(
      now.toIso8601String(),
      draft,
    );
    debugPrint('ProactiveMessageService [后台]: 已写入主动消息: "$draft"');

    // 7. 发送本地通知（第四面墙命名：不暴露"AI/大模型"）
    const androidDetails = AndroidNotificationDetails(
      _notificationChannelId,
      _notificationChannelName,
      channelDescription: '来自TA的主动消息',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );
    const details = NotificationDetails(android: androidDetails);

    await plugin.show(
      now.millisecondsSinceEpoch ~/ 1000 % 2147483647,
      '$characterName 给你发来了消息',
      draft,
      details,
    );
  }

  /// 前台消费：读取并展示所有未发送的主动消息到对话流水
  /// 返回已消费的消息列表，调用方负责写入 UI 并调用 markSent
  static Future<List<Map<String, dynamic>>> consumePendingMessages() async {
    return await DbHelper.instance.getUnsentScheduledMessages();
  }

  /// 将指定消息标记为已在前台展示
  static Future<void> markConsumed(int id) async {
    await DbHelper.instance.markScheduledMessageSent(id);
  }
}
