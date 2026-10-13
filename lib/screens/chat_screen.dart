import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huainian/database/db_helper.dart';
import 'package:huainian/models/character_style.dart';
import 'package:huainian/models/chat_message.dart';
import 'package:huainian/screens/settings_screen.dart';
import 'package:huainian/services/ambience_service.dart';
import 'package:huainian/services/chat_service.dart';
import 'package:huainian/services/proactive_message_service.dart';
import 'package:huainian/state/app_providers.dart';

/// V6.0 — QQ 风格聊天主界面
/// 视觉规范：QQ 蓝顶栏 / 灰蓝背景 / 左侧白色气泡 + 右侧浅蓝气泡（带尾巴）
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
  // QQ 视觉常量
  static const Color _qqBlue = Color(0xFF12B7F5);
  static const Color _qqBlueDark = Color(0xFF009FE8);
  static const Color _bgColor = Color(0xFFF2F3F7);
  static const Color _userBubbleColor = Color(0xFF9FD9F6);
  static const Color _assistantBubbleColor = Colors.white;

  final List<ChatMessage> _messages = [];
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ChatService _chatService = ChatService();

  String _characterName = '';
  String _sleepStart = '23:00';
  String _sleepEnd = '06:00';
  List<String> _allowedSymbols = [];
  bool _isLoading = true;
  bool _isSending = false;
  String? _loadError;

  // 打字机状态
  Timer? _typewriterTimer;
  String? _typewriterTarget;
  int _typewriterIndex = -1;

  bool get _isSleeping => ChatService.isInSleepRange(_sleepStart, _sleepEnd);

  /// V7.0 R4：发给大模型的上下文滑窗大小（最近 N 条 user/assistant 消息）
  /// 控制 token 消耗，更早的历史由记忆召回机制兜底
  static const int _contextWindowSize = 20;

  /// V7.0 R4：最近一次发送失败的用户输入（供错误气泡点按重发）
  String? _lastFailedInput;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _inputController.addListener(_onInputChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadConversation();
      await _requestNotificationPermission();
      // V7.0：同步背景音乐播放状态（配置为开启时进入聊天即播放）
      AmbienceService.instance.syncPlayback();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelTypewriter(snapToFull: false);
    _inputController.removeListener(_onInputChanged);
    _inputController.dispose();
    _scrollController.dispose();
    _chatService.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkProactiveMessages();
    }
  }

  void _onInputChanged() {
    setState(() {});
  }

  // ── 初始化加载 ─────────────────────────────────────────────────────────────

  Future<void> _loadConversation() async {
    if (!mounted) return;
    _cancelTypewriter(snapToFull: false);
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      // V7.0：同步读取聊天背景图配置
      final bgPath = await AmbienceService.instance.getChatBackgroundPath();
      if (mounted) {
        ref.read(chatBackgroundProvider.notifier).state = bgPath ?? '';
      }

      final config = await DbHelper.instance.getCharacterConfig();
      if (!mounted) return;
      if (config == null) {
        setState(() {
          _loadError = '角色配置读取失败，请前往通讯设置建立连接';
          _isLoading = false;
        });
        return;
      }

      final name = config['name'] as String? ?? 'TA';
      final start = config['sleep_start'] as String? ?? '23:00';
      final end = config['sleep_end'] as String? ?? '06:00';

      // 解析角色专属符号（供输入栏符号面板使用）
      List<String> symbols = [];
      final styleJsonStr = config['style_json'] as String?;
      if (styleJsonStr != null && styleJsonStr.isNotEmpty) {
        try {
          final styleMap = jsonDecode(styleJsonStr) as Map<String, dynamic>;
          symbols = CharacterStyle.fromJson(styleMap).allowedSymbols;
        } catch (_) {
          symbols = [];
        }
      }

      final rows = await DbHelper.instance.getRecentMessages();
      if (!mounted) return;

      final msgs = rows
          .map((r) => ChatMessage.fromDbRow(r))
          .where((m) => m.content.isNotEmpty)
          .toList();

      setState(() {
        _characterName = name;
        _sleepStart = start;
        _sleepEnd = end;
        _allowedSymbols = symbols;
        _messages
          ..clear()
          ..addAll(msgs);
        _isLoading = false;
      });

      await _checkProactiveMessages();
      _scrollToBottom(animate: false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = '加载失败: ${e.toString().replaceAll('Exception:', '').trim()}';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _checkProactiveMessages() async {
    if (!mounted) return;
    try {
      final pending = await ProactiveMessageService.consumePendingMessages();
      if (pending.isEmpty || !mounted) return;
      final newMsgs = <ChatMessage>[];
      for (final msg in pending) {
        final id = msg['id'] as int?;
        final content =
            (msg['content_draft'] as String? ?? '').trim();
        if (id == null || content.isEmpty) continue;
        try {
          await DbHelper.instance.insertMessage('assistant', content);
          await ProactiveMessageService.markConsumed(id);
          newMsgs.add(ChatMessage(
            role: MessageRole.assistant,
            content: content,
            timestamp: DateTime.now(),
          ));
        } catch (_) {
          // 单条消费失败不中断整体
        }
      }
      if (newMsgs.isNotEmpty && mounted) {
        setState(() => _messages.addAll(newMsgs));
        _scrollToBottom();
      }
    } catch (_) {
      // 主动消息消费失败不影响主流程
    }
  }

  Future<void> _requestNotificationPermission() async {
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {
      // 权限请求失败非致命错误
    }
  }

  // ── 发送消息 ───────────────────────────────────────────────────────────────

  Future<void> _sendMessage({String? retryOf}) async {
    final bool isRetry = retryOf != null;
    final text = (retryOf ?? _inputController.text).trim();
    if (text.isEmpty || _isSending) return;

    // 输入长度校验
    if (text.length > 500) {
      _showSnackBar('消息过长，请控制在500字以内');
      return;
    }

    _cancelTypewriter(snapToFull: true);
    if (!isRetry) _inputController.clear();

    final now = DateTime.now();

    // ── 睡眠拦截（重试场景不会出现：睡眠时消息留待醒来，不产生错误气泡）─────
    if (!isRetry && _isSleeping) {
      final userMsg =
          ChatMessage(role: MessageRole.user, content: text, timestamp: now);
      final notice = ChatMessage(
        role: MessageRole.sleepNotice,
        content: 'TA正在休息中，消息将留至醒来后看到',
        timestamp: now,
      );
      setState(() {
        _messages.add(userMsg);
        _messages.add(notice);
      });
      _scrollToBottom();
      try {
        await DbHelper.instance.insertMessage('user', text);
      } catch (e) {
        if (mounted) _showSnackBar('消息保存失败，请检查存储空间');
      }
      return;
    }

    // ── 构建上下文（只含 user/assistant 角色，V7.0 R4 限最近 N 条滑窗）─────
    final List<Map<String, String>> history = [];
    for (final m in _messages) {
      if (m.isUser) {
        history.add({'role': 'user', 'content': m.content});
      } else if (m.isAssistant &&
          !_isErrorContent(m.content) &&
          m.content != '···') {
        // 错误气泡与占位符不进入上下文，避免污染对话
        history.add({'role': 'assistant', 'content': m.content});
      }
    }
    // 重试时用户消息已在历史末尾（首轮已上屏入库），不重复追加
    if (!isRetry) {
      history.add({'role': 'user', 'content': text});
    }
    final List<Map<String, String>> context =
        history.length > _contextWindowSize
            ? history.sublist(history.length - _contextWindowSize)
            : history;

    // ── 立即将用户消息和占位符写入 UI（重试时用户消息已存在，只加占位符）───
    final placeholder = ChatMessage(
      role: MessageRole.assistant,
      content: '···',
      timestamp: now,
    );
    setState(() {
      if (!isRetry) {
        _messages.add(ChatMessage(
            role: MessageRole.user, content: text, timestamp: now));
      }
      _messages.add(placeholder);
      _isSending = true;
    });
    final int placeholderIndex = _messages.length - 1;
    _scrollToBottom();

    try {
      // 重试时用户消息首轮已写入回忆录，不重复入库
      if (!isRetry) {
        await DbHelper.instance.insertMessage('user', text);
      }

      final reply = await _chatService.sendChatMessage(context);
      if (!mounted) return;

      final recalled = List<String>.from(_chatService.lastRecalledFacts);

      // 错误回复（通讯中断/密钥未配置等）只上屏展示，不写入回忆录，
      // 防止污染后续记忆提炼的语料；同时记录失败输入供点按重发
      final bool isErrorReply = _isErrorContent(reply);
      if (!isErrorReply) {
        await DbHelper.instance.insertMessage('assistant', reply);
        _lastFailedInput = null;
      } else {
        _lastFailedInput = text;
      }

      if (!mounted) return;
      setState(() => _isSending = false);

      if (recalled.isNotEmpty && !isErrorReply) {
        setState(() {
          _messages.add(ChatMessage(
            role: MessageRole.memoryRecall,
            content: recalled.join('  ·  '),
            timestamp: DateTime.now(),
          ));
        });
      }

      _playTypewriter(reply, placeholderIndex);
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      _lastFailedInput = text;
      final errText =
          '通讯中断: ${e.toString().replaceAll('Exception:', '').trim()}';
      setState(() {
        if (placeholderIndex < _messages.length) {
          _messages[placeholderIndex] =
              _messages[placeholderIndex].copyWith(content: errText);
        }
        _isSending = false;
      });
    }
  }

  /// 错误类回复判定（错误/异常前缀的 API 失败 + 本地通讯中断占位）
  static bool _isErrorContent(String content) =>
      content.startsWith('错误：') ||
      content.startsWith('异常：') ||
      content.startsWith('通讯中断');

  /// V7.0 R4：点按错误气泡重发——移除错误气泡后以原输入重新走发送流程
  void _retryFailedMessage(ChatMessage errorMsg) {
    final failedInput = _lastFailedInput;
    if (failedInput == null || _isSending) return;
    // 先停掉可能正在播放的错误文本打字机，防止移除气泡后索引位移、
    // Timer 将错误文本写进相邻消息
    _cancelTypewriter(snapToFull: false);
    setState(() {
      _messages.remove(errorMsg);
      _lastFailedInput = null;
    });
    _sendMessage(retryOf: failedInput);
  }

  // ── 打字机效果 ─────────────────────────────────────────────────────────────

  void _cancelTypewriter({required bool snapToFull}) {
    _typewriterTimer?.cancel();
    _typewriterTimer = null;
    if (snapToFull &&
        _typewriterTarget != null &&
        _typewriterIndex >= 0 &&
        _typewriterIndex < _messages.length &&
        mounted) {
      setState(() {
        _messages[_typewriterIndex] =
            _messages[_typewriterIndex].copyWith(content: _typewriterTarget!);
      });
    }
    _typewriterTarget = null;
    _typewriterIndex = -1;
  }

  void _playTypewriter(String text, int messageIndex) {
    _cancelTypewriter(snapToFull: false);
    if (text.isEmpty ||
        messageIndex < 0 ||
        messageIndex >= _messages.length) {
      return;
    }
    _typewriterTarget = text;
    _typewriterIndex = messageIndex;
    int charIndex = 0;
    _typewriterTimer =
        Timer.periodic(const Duration(milliseconds: 40), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      charIndex++;
      if (charIndex >= text.length) {
        timer.cancel();
        _typewriterTimer = null;
        _typewriterTarget = null;
        _typewriterIndex = -1;
        setState(() {
          if (messageIndex < _messages.length) {
            _messages[messageIndex] =
                _messages[messageIndex].copyWith(content: text);
          }
        });
        return;
      }
      setState(() {
        if (messageIndex < _messages.length) {
          _messages[messageIndex] = _messages[messageIndex]
              .copyWith(content: text.substring(0, charIndex));
        }
      });
    });
  }

  // ── 工具方法 ───────────────────────────────────────────────────────────────

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (pos.maxScrollExtent <= 0) return;
      if (animate) {
        _scrollController.animateTo(
          pos.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        _scrollController.jumpTo(pos.maxScrollExtent);
      }
    });
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _copyMessage(String content) {
    Clipboard.setData(ClipboardData(text: content));
    _showSnackBar('已复制');
  }

  void _insertSymbol(String symbol) {
    final current = _inputController.text;
    final selection = _inputController.selection;
    final int insertAt =
        (selection.isValid && selection.start >= 0) ? selection.start : current.length;
    final newText = current.substring(0, insertAt) +
        symbol +
        current.substring(insertAt);
    _inputController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: insertAt + symbol.length),
    );
  }

  void _showSymbolPanel() {
    if (_allowedSymbols.isEmpty) {
      _showSnackBar('暂未开放');
      return;
    }
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TA 的专属符号',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: _allowedSymbols.map((s) {
                    return InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        _insertSymbol(s);
                        Navigator.pop(ctx);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF2F3F7),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(s, style: const TextStyle(fontSize: 16)),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _navigateToSettings() async {
    final nameBefore = _characterName;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    if (!mounted) return;
    // V7.0：设置页可能变更了背景图/音乐，返回后无条件刷新氛围配置
    try {
      final bgPath = await AmbienceService.instance.getChatBackgroundPath();
      if (mounted) {
        ref.read(chatBackgroundProvider.notifier).state = bgPath ?? '';
      }
      AmbienceService.instance.syncPlayback();
    } catch (_) {}
    try {
      final config = await DbHelper.instance.getCharacterConfig();
      if (!mounted) return;
      final nameAfter = config?['name'] as String? ?? nameBefore;
      if (nameAfter != nameBefore) {
        _chatService.clearDeduplicationCache();
        await _loadConversation();
      } else {
        setState(() {
          _characterName = nameAfter;
          _sleepStart =
              config?['sleep_start'] as String? ?? '23:00';
          _sleepEnd = config?['sleep_end'] as String? ?? '06:00';
        });
      }
    } catch (_) {
      // 设置返回后刷新失败不阻塞主流程
    }
  }

  // ── 构建方法 ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final String bgPath = ref.watch(chatBackgroundProvider) ?? '';
    final bool hasBg = bgPath.isNotEmpty; // 文件缺失时由 errorBuilder 兜底
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: _buildAppBar(),
      body: Stack(
        children: [
          // V7.0：用户自定义聊天背景图 + 可读性柔光遮罩
          if (hasBg) ...[
            Positioned.fill(
              child: Image.file(
                File(bgPath),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
            Positioned.fill(
              child: Container(color: _bgColor.withValues(alpha: 0.55)),
            ),
          ],
          Column(
            children: [
              Expanded(child: _buildBody()),
              if (_isSleeping) _buildSleepBanner(),
              _buildInputRow(),
            ],
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _qqBlue,
      foregroundColor: Colors.white,
      centerTitle: true,
      elevation: 0.5,
      automaticallyImplyLeading: false,
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _characterName.isEmpty ? '...' : _characterName,
            style: const TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600),
          ),
          if (_isSleeping)
            const Text(
              '休息中',
              style: TextStyle(fontSize: 11, color: Colors.white70),
            ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.more_horiz),
          tooltip: '通讯设置',
          onPressed: _navigateToSettings,
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(
          child: CircularProgressIndicator(color: _qqBlue));
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: Colors.grey.shade400),
              const SizedBox(height: 12),
              Text(
                _loadError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadConversation,
                icon: const Icon(Icons.refresh),
                label: const Text('重新加载'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _qqBlue,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_messages.isEmpty) {
      return Center(
        child: Text(
          '发送第一条消息，开始对话',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        final prev = index > 0 ? _messages[index - 1] : null;
        return _buildItem(msg, prev);
      },
    );
  }

  Widget _buildItem(ChatMessage msg, ChatMessage? prev) {
    if (msg.isSleepNotice) return _buildSleepNoticeItem(msg);
    if (msg.isMemoryRecall) return _buildMemoryRecallItem(msg);

    Widget? divider;
    if (prev != null && !prev.isSleepNotice && !prev.isMemoryRecall) {
      final gap = msg.timestamp.difference(prev.timestamp).abs();
      if (gap.inMinutes >= 5) divider = _buildTimeDivider(msg.timestamp);
    }

    final bubble =
        msg.isUser ? _buildUserBubble(msg) : _buildAssistantBubble(msg);
    if (divider != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [divider, bubble],
      );
    }
    return bubble;
  }

  /// QQ 风格时间分隔：居中纯灰色小字，无药丸背景
  Widget _buildTimeDivider(DateTime ts) {
    final now = DateTime.now();
    final sameDay = now.year == ts.year &&
        now.month == ts.month &&
        now.day == ts.day;
    final label = sameDay
        ? '${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}'
        : '${ts.month}/${ts.day} ${ts.hour.toString().padLeft(2, '0')}:${ts.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Text(
          label,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
        ),
      ),
    );
  }

  /// QQ 风格用户气泡：右侧，浅蓝底 + 右向尾巴
  Widget _buildUserBubble(ChatMessage msg) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 48),
          Flexible(
            child: GestureDetector(
              onLongPress: () => _copyMessage(msg.content),
              child: CustomPaint(
                painter: const _BubbleTailPainter(
                  color: _userBubbleColor,
                  isLeft: false,
                ),
                child: Container(
                  margin: const EdgeInsets.only(right: 7),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  child: Text(
                    msg.content,
                    style: const TextStyle(
                        fontSize: 15, color: Colors.black87, height: 1.35),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _buildAvatar(text: '我', color: _qqBlueDark),
        ],
      ),
    );
  }

  /// QQ 风格对方气泡：左侧，白底 + 左向尾巴；错误气泡红色文案 + 点按重发
  Widget _buildAssistantBubble(ChatMessage msg) {
    final initial = (_characterName.isNotEmpty) ? _characterName[0] : 'T';
    final bool isError = _isErrorContent(msg.content);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAvatar(text: initial, color: const Color(0xFF8E9EAB)),
          const SizedBox(width: 6),
          Flexible(
            child: GestureDetector(
              onLongPress: () => _copyMessage(msg.content),
              onTap: isError ? () => _retryFailedMessage(msg) : null,
              child: CustomPaint(
                painter: const _BubbleTailPainter(
                  color: _assistantBubbleColor,
                  isLeft: true,
                ),
                child: Container(
                  margin: const EdgeInsets.only(left: 7),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        msg.content,
                        style: TextStyle(
                          fontSize: 15,
                          color: isError
                              ? Colors.red.shade700
                              : Colors.black87,
                          height: 1.35,
                        ),
                      ),
                      if (isError) ...[
                        const SizedBox(height: 4),
                        Text(
                          '点按重发',
                          style: TextStyle(
                            fontSize: 11,
                            color: _qqBlue.withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildAvatar({required String text, required Color color}) {
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildSleepNoticeItem(ChatMessage msg) {
    return Padding(
      padding: const EdgeInsets.only(
          left: 52, right: 52, bottom: 8, top: 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 11, color: Colors.grey.shade500),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              msg.content,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade500,
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemoryRecallItem(ChatMessage msg) {
    return Padding(
      padding: const EdgeInsets.only(
          left: 52, right: 20, bottom: 8, top: 0),
      child: Row(
        children: [
          Icon(Icons.auto_awesome,
              size: 11, color: _qqBlue.withValues(alpha: 0.6)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '记忆激活: ${msg.content}',
              style: TextStyle(
                fontSize: 10,
                color: _qqBlueDark.withValues(alpha: 0.7),
                fontStyle: FontStyle.italic,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSleepBanner() {
    return Container(
      width: double.infinity,
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: Colors.grey.shade100,
      child: Row(
        children: [
          Icon(Icons.bedtime_outlined,
              size: 14, color: Colors.grey.shade500),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'TA正在休息中（$_sleepStart–$_sleepEnd），消息将在TA醒来后看到',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade600,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// QQ 风格输入栏：白底 + 圆角灰输入框 + 符号面板 + 发送/加号切换
  Widget _buildInputRow() {
    final canSend =
        !_isSending && _inputController.text.trim().isNotEmpty;
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // 符号面板入口
            GestureDetector(
              onTap: _showSymbolPanel,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Icon(Icons.emoji_emotions_outlined,
                    size: 26, color: Colors.grey.shade600),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 100),
                child: TextField(
                  controller: _inputController,
                  maxLines: null,
                  maxLength: 500,
                  buildCounter: (context,
                      {required currentLength,
                      required isFocused,
                      maxLength}) {
                    if (currentLength >= 450 && maxLength != null) {
                      return Text(
                        '$currentLength/$maxLength',
                        style: TextStyle(
                          fontSize: 10,
                          color: currentLength >= 480
                              ? Colors.red
                              : Colors.grey.shade500,
                        ),
                      );
                    }
                    return null;
                  },
                  decoration: InputDecoration(
                    hintText: _isSleeping
                        ? 'TA正在休息中，消息将留至醒来后...'
                        : '发送消息...',
                    hintStyle: TextStyle(
                        color: Colors.grey.shade500, fontSize: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: const Color(0xFFF2F3F7),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 9),
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) {
                    if (canSend) _sendMessage();
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            // QQ 行为：有内容时显示「发送」，否则显示「+」
            if (canSend)
              GestureDetector(
                onTap: _isSending ? null : _sendMessage,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: _isSending ? Colors.grey.shade300 : _qqBlue,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _isSending ? '···' : '发送',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              )
            else
              GestureDetector(
                onTap: () => _showSnackBar('暂未开放'),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Icon(Icons.add_circle_outline,
                      size: 26, color: Colors.grey.shade600),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// QQ 气泡尾巴绘制器：圆角矩形 + 朝向头像的小三角
class _BubbleTailPainter extends CustomPainter {
  final Color color;

  /// true = 尾巴在左侧（对方气泡）；false = 尾巴在右侧（用户气泡）
  final bool isLeft;

  const _BubbleTailPainter({required this.color, required this.isLeft});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    const double tailWidth = 7;
    const double tailHeight = 10;
    const double tailTop = 14; // 尾巴顶点距气泡顶部的偏移（对齐头像中心附近）

    final double bodyLeft = isLeft ? tailWidth : 0;
    final double bodyRight = isLeft ? size.width : size.width - tailWidth;

    // 气泡主体（圆角矩形）
    final rrect = RRect.fromLTRBR(
      bodyLeft,
      0,
      bodyRight,
      size.height,
      const Radius.circular(8),
    );
    canvas.drawRRect(rrect, paint);

    // 尾巴三角
    final path = Path();
    if (isLeft) {
      path.moveTo(bodyLeft, tailTop);
      path.lineTo(0, tailTop + tailHeight / 2);
      path.lineTo(bodyLeft, tailTop + tailHeight);
    } else {
      path.moveTo(bodyRight, tailTop);
      path.lineTo(size.width, tailTop + tailHeight / 2);
      path.lineTo(bodyRight, tailTop + tailHeight);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_BubbleTailPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.isLeft != isLeft;
}
