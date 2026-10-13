import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:huainian/config/constants.dart';
import 'package:huainian/database/db_helper.dart';

/// V7.0 — 氛围服务：聊天背景图与背景音乐的统一管理
///
/// 职责：
///   1. 用户选取的 图片/音频 复制进应用沙盒（防止原文件被清理后失效）
///   2. 配置读写（app_settings 表：路径 / 开关 / 音量）
///   3. 背景音乐播放控制（audioplayers 循环播放，跨页面持续）
class AmbienceService {
  AmbienceService._();
  static final AmbienceService instance = AmbienceService._();

  final AudioPlayer _player = AudioPlayer();
  bool _playerConfigured = false;

  /// 沙盒内用户氛围文件目录
  Future<Directory> _ambienceDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'ambience'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ── 背景图 ────────────────────────────────────────────────────────────────

  /// 将用户选取的图片复制进沙盒并记录路径，返回沙盒内路径
  Future<String> setChatBackground(String sourcePath) async {
    final dir = await _ambienceDir();
    final ext = p.extension(sourcePath).isNotEmpty
        ? p.extension(sourcePath)
        : '.jpg';
    final destPath = p.join(dir.path, 'chat_bg$ext');
    await File(sourcePath).copy(destPath);
    await DbHelper.instance.setSetting(AppConstants.keyChatBgPath, destPath);
    return destPath;
  }

  /// 清除聊天背景图（先读路径再清配置，否则文件会泄漏在沙盒中）
  Future<void> clearChatBackground() async {
    final old = await getChatBackgroundPath();
    await DbHelper.instance.setSetting(AppConstants.keyChatBgPath, '');
    if (old != null) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
  }

  /// 当前生效的背景图路径（不存在或文件已丢失返回 null）
  Future<String?> getChatBackgroundPath() async {
    final path = await DbHelper.instance.getSetting(AppConstants.keyChatBgPath);
    if (path == null || path.isEmpty) return null;
    if (!await File(path).exists()) return null;
    return path;
  }

  // ── 背景音乐 ──────────────────────────────────────────────────────────────

  /// 将用户选取的音频复制进沙盒并记录路径，返回沙盒内路径
  Future<String> setBgm(String sourcePath) async {
    final dir = await _ambienceDir();
    final ext = p.extension(sourcePath).isNotEmpty
        ? p.extension(sourcePath)
        : '.mp3';
    final destPath = p.join(dir.path, 'bgm$ext');
    await File(sourcePath).copy(destPath);
    await DbHelper.instance.setSetting(AppConstants.keyBgmPath, destPath);
    // 设置了新音乐即默认开启播放
    await setBgmEnabled(true);
    await syncPlayback();
    return destPath;
  }

  Future<void> clearBgm() async {
    await stop();
    await DbHelper.instance.setSetting(AppConstants.keyBgmPath, '');
    await DbHelper.instance.setSetting(AppConstants.keyBgmEnabled, 'false');
    try {
      final dir = await _ambienceDir();
      await for (final entity in dir.list()) {
        if (entity is File && p.basename(entity.path).startsWith('bgm')) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  Future<String?> getBgmPath() async {
    final path = await DbHelper.instance.getSetting(AppConstants.keyBgmPath);
    if (path == null || path.isEmpty) return null;
    if (!await File(path).exists()) return null;
    return path;
  }

  Future<bool> isBgmEnabled() async {
    final v = await DbHelper.instance.getSetting(AppConstants.keyBgmEnabled);
    return v == 'true';
  }

  Future<void> setBgmEnabled(bool enabled) async {
    await DbHelper.instance
        .setSetting(AppConstants.keyBgmEnabled, enabled ? 'true' : 'false');
  }

  Future<double> getBgmVolume() async {
    final v = await DbHelper.instance.getSetting(AppConstants.keyBgmVolume);
    return double.tryParse(v ?? '') ?? 0.5;
  }

  Future<void> setBgmVolume(double volume) async {
    await DbHelper.instance
        .setSetting(AppConstants.keyBgmVolume, volume.toStringAsFixed(2));
    try {
      await _player.setVolume(volume);
    } catch (_) {}
  }

  // ── 播放控制 ──────────────────────────────────────────────────────────────

  /// 根据当前配置同步播放状态（App 启动、设置变更后调用）
  /// 配置为开启且音频文件存在 → 循环播放；否则停止
  Future<void> syncPlayback() async {
    try {
      final enabled = await isBgmEnabled();
      final path = await getBgmPath();
      if (!enabled || path == null) {
        await stop();
        return;
      }
      if (!_playerConfigured) {
        await _player.setReleaseMode(ReleaseMode.loop);
        _playerConfigured = true;
      }
      await _player.setVolume(await getBgmVolume());
      // 已在播放同一音源时不重启，避免设置页微调音量导致音乐重头开始
      if (_player.state != PlayerState.playing) {
        await _player.play(DeviceFileSource(path));
      }
    } catch (e) {
      debugPrint('AmbienceService [播放同步失败]: $e');
    }
  }

  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
  }

  void dispose() {
    _player.dispose();
  }
}
