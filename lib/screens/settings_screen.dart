import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huainian/config/constants.dart';
import 'package:huainian/database/db_helper.dart';
import 'package:huainian/services/llm_api_service.dart';
import 'package:huainian/state/app_providers.dart';

/// V6.0 — 通讯设置（QQ 风格）
/// 分区：当前通讯对象 / 连接配置（API）/ 建立连接 / 深层记忆 / 断开连接
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const Color _qqBlue = Color(0xFF12B7F5);
  static const Color _bgColor = Color(0xFFF2F3F7);

  String _characterName = '加载中...';
  String _sleepStart = '23:00';
  String _sleepEnd = '06:00';
  bool _isResetting = false;

  // ── 连接配置（API）状态 ──────────────────────────────────────────────────
  final TextEditingController _baseUrlController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  bool _obscureKey = true;
  bool _isSavingConfig = false;
  bool _isTesting = false;
  String? _apiTestResult;
  bool _apiTestSuccess = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCharacterInfo();
      _loadApiConfig();
    });
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _loadCharacterInfo() async {
    try {
      final config = await DbHelper.instance.getCharacterConfig();
      if (!mounted || config == null) return;
      setState(() {
        _characterName = config['name'] as String? ?? '未知';
        _sleepStart = config['sleep_start'] as String? ?? '23:00';
        _sleepEnd = config['sleep_end'] as String? ?? '06:00';
      });
    } catch (_) {
      if (mounted) setState(() => _characterName = '读取失败');
    }
  }

  // ── 连接配置读写 ───────────────────────────────────────────────────────────

  Future<void> _loadApiConfig() async {
    try {
      final db = DbHelper.instance;
      final baseUrl = await db.getSetting(AppConstants.keyApiBaseUrl);
      final apiKey = await db.getSetting(AppConstants.keyApiKey);
      final model = await db.getSetting(AppConstants.keyModelName);
      if (!mounted) return;
      setState(() {
        _baseUrlController.text = (baseUrl != null && baseUrl.isNotEmpty)
            ? baseUrl
            : AppConstants.defaultApiBaseUrl;
        _apiKeyController.text = apiKey ?? '';
        _modelController.text = (model != null && model.isNotEmpty)
            ? model
            : AppConstants.defaultModelName;
      });
    } catch (_) {
      // 配置读取失败时保持输入框为空，不阻塞页面
    }
  }

  Future<void> _saveApiConfig({bool silent = false}) async {
    final db = DbHelper.instance;
    await db.setSetting(
        AppConstants.keyApiBaseUrl, _baseUrlController.text.trim());
    await db.setSetting(
        AppConstants.keyApiKey, _apiKeyController.text.trim());
    await db.setSetting(
        AppConstants.keyModelName, _modelController.text.trim());
    if (!silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('连接配置已保存'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  /// 配置合法性预检：地址必须为 http(s)，模型名必填
  String? _validateConfigInput() {
    final baseUrl = _baseUrlController.text.trim();
    if (!baseUrl.startsWith('http://') && !baseUrl.startsWith('https://')) {
      return '服务地址必须以 http:// 或 https:// 开头';
    }
    if (_modelController.text.trim().isEmpty) {
      return '模型名称不能为空';
    }
    return null;
  }

  Future<void> _onSaveConfigPressed() async {
    if (_isSavingConfig) return;
    final inputError = _validateConfigInput();
    if (inputError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(inputError), backgroundColor: Colors.red),
      );
      return;
    }
    setState(() => _isSavingConfig = true);
    try {
      await _saveApiConfig();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingConfig = false);
    }
  }

  /// 测试连接：先静默保存当前输入，再以最小请求验证 地址/密钥/模型 三者可用
  Future<void> _onTestConnectionPressed() async {
    if (_isTesting) return;
    final inputError = _validateConfigInput();
    if (inputError != null) {
      setState(() {
        _apiTestSuccess = false;
        _apiTestResult = inputError;
      });
      return;
    }
    setState(() {
      _isTesting = true;
      _apiTestResult = null;
    });
    try {
      await _saveApiConfig(silent: true);
      final reply = await ref.read(llmApiServiceProvider).testConnection();
      if (!mounted) return;
      setState(() {
        _apiTestSuccess = true;
        final short =
            reply.length > 20 ? '${reply.substring(0, 20)}…' : reply;
        _apiTestResult = '连接正常，对端回应：$short';
      });
    } on LlmApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _apiTestSuccess = false;
        _apiTestResult = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _apiTestSuccess = false;
        _apiTestResult = '测试失败: $e';
      });
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  // ── 断开连接 ───────────────────────────────────────────────────────────────

  Future<void> _resetConnection() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('断开连接'),
        content: const Text(
          '这将清除所有对话记录和角色设定，回到初始状态。\n\n此操作不可撤销，确认继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认断开'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isResetting = true);
    try {
      await DbHelper.instance.clearDatabase();
      await DbHelper.instance.clearMemoryFacts();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('连接已断开，所有记录已清除'),
          duration: Duration(seconds: 2),
        ),
      );
      await _loadCharacterInfo();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('操作失败: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 3),
        ),
      );
    } finally {
      if (mounted) setState(() => _isResetting = false);
    }
  }

  void _showFactsDialog() {
    showDialog(
      context: context,
      builder: (_) => const _MemoryFactsDialog(),
    );
  }

  // ── 构建 ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final importState = ref.watch(importStateProvider);
    final distillState = ref.watch(distillationStateProvider);
    final isGlobalLocked = _isResetting || importState.isLoading;

    ref.listen<ImportState>(importStateProvider, (previous, next) {
      if (next.phase == ImportPhase.done) _loadCharacterInfo();
    });

    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        title: const Text('通讯设置'),
        centerTitle: true,
        backgroundColor: _qqBlue,
        foregroundColor: Colors.white,
        elevation: 0.5,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 当前角色信息 ──────────────────────────────────────
            _SectionCard(
              title: '当前通讯对象',
              titleIcon: Icons.person_outline,
              child: Column(
                children: [
                  _InfoRow(label: '角色称呼', value: _characterName),
                  const Divider(height: 1),
                  _InfoRow(
                    label: '休息时段',
                    value: '$_sleepStart – $_sleepEnd',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ── 连接配置（API）────────────────────────────────────
            _SectionCard(
              title: '连接配置',
              titleIcon: Icons.settings_input_antenna,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildConfigField(
                    controller: _baseUrlController,
                    label: '服务地址',
                    hint: AppConstants.defaultApiBaseUrl,
                  ),
                  const SizedBox(height: 10),
                  _buildConfigField(
                    controller: _apiKeyController,
                    label: '连接密钥',
                    hint: '请输入密钥',
                    obscure: _obscureKey,
                    suffix: IconButton(
                      icon: Icon(
                        _obscureKey
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 18,
                        color: Colors.grey.shade500,
                      ),
                      onPressed: () =>
                          setState(() => _obscureKey = !_obscureKey),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _buildConfigField(
                    controller: _modelController,
                    label: '模型名称',
                    hint: AppConstants.defaultModelName,
                  ),
                  if (_apiTestResult != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _apiTestSuccess
                            ? Colors.green.shade50
                            : Colors.red.shade50,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _apiTestResult!,
                        style: TextStyle(
                          fontSize: 12,
                          color: _apiTestSuccess
                              ? Colors.green.shade800
                              : Colors.red.shade700,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed:
                              _isSavingConfig ? null : _onSaveConfigPressed,
                          icon: const Icon(Icons.save_outlined, size: 18),
                          label: const Text('保存配置'),
                          style: FilledButton.styleFrom(
                            backgroundColor: _qqBlue,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed:
                              _isTesting ? null : _onTestConnectionPressed,
                          icon: _isTesting
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.wifi_tethering, size: 18),
                          label: Text(_isTesting ? '测试中...' : '测试连接'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _qqBlue,
                            side: const BorderSide(color: _qqBlue),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ── 建立连接 ──────────────────────────────────────────
            _SectionCard(
              title: '建立连接',
              titleIcon: Icons.link,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusBox(
                    text: importState.previewText,
                    phase: importState.phase,
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: isGlobalLocked
                        ? null
                        : () =>
                            ref.read(importStateProvider.notifier).triggerImport(),
                    icon: importState.phase == ImportPhase.extractingStyle
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.folder_open),
                    label: Text(
                      importState.phase == ImportPhase.extractingStyle
                          ? '分析中，请稍候...'
                          : '导入聊天记录以建立连接',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: _qqBlue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ── 深层记忆 ──────────────────────────────────────────
            _SectionCard(
              title: '深层记忆',
              titleIcon: Icons.psychology,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (distillState.isRunning &&
                      distillState.totalBatches > 0) ...[
                    LinearProgressIndicator(
                      value: distillState.completedBatches /
                          distillState.totalBatches,
                      backgroundColor: Colors.deepPurple.shade50,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.deepPurple.shade400),
                    ),
                    const SizedBox(height: 6),
                  ],
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: _distillBgColor(distillState.phase),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      distillState.statusText,
                      style: TextStyle(
                        fontSize: 13,
                        color: distillState.phase == DistillationPhase.error
                            ? Colors.red.shade700
                            : distillState.phase == DistillationPhase.done
                                ? Colors.deepPurple.shade800
                                : Colors.grey.shade700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: (isGlobalLocked || distillState.isRunning)
                              ? null
                              : () => ref
                                  .read(distillationStateProvider.notifier)
                                  .startDistillation(),
                          icon: distillState.isRunning
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.auto_awesome),
                          label: Text(distillState.isRunning
                              ? '整理中，请稍候...'
                              : '开始整理长期记忆'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.deepPurple.shade400,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                      if (distillState.phase == DistillationPhase.done) ...[
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: _showFactsDialog,
                          icon: const Icon(Icons.list_alt, size: 18),
                          label: const Text('查看碎片'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.deepPurple.shade400,
                            side: BorderSide(color: Colors.deepPurple.shade200),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ── 断开连接（危险区域）────────────────────────────────
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: ListTile(
                leading: _isResetting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.link_off, color: Colors.red.shade600),
                title: Text(
                  '断开连接',
                  style: TextStyle(
                    color: Colors.red.shade700,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: const Text(
                  '清除全部对话记录及角色设定',
                  style: TextStyle(fontSize: 12),
                ),
                onTap: (isGlobalLocked || _isResetting) ? null : _resetConnection,
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigField({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
            filled: true,
            fillColor: _bgColor,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            isDense: true,
            suffixIcon: suffix,
          ),
        ),
      ],
    );
  }

  Color _distillBgColor(DistillationPhase phase) {
    switch (phase) {
      case DistillationPhase.done:
        return Colors.deepPurple.shade50;
      case DistillationPhase.error:
        return Colors.red.shade50;
      default:
        return Colors.grey.shade100;
    }
  }
}

// ── 复用小组件 ──────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData titleIcon;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.titleIcon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(titleIcon, size: 16, color: const Color(0xFF12B7F5)),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
          ),
          const Spacer(),
          Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _StatusBox extends StatelessWidget {
  final String text;
  final ImportPhase phase;

  const _StatusBox({required this.text, required this.phase});

  @override
  Widget build(BuildContext context) {
    Color bgColor;
    Color textColor;
    switch (phase) {
      case ImportPhase.done:
        bgColor = const Color(0xFFE5F6FD);
        textColor = const Color(0xFF0077B6);
        break;
      case ImportPhase.error:
        bgColor = Colors.red.shade50;
        textColor = Colors.red.shade700;
        break;
      default:
        bgColor = Colors.grey.shade100;
        textColor = Colors.grey.shade700;
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 150),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: textColor),
        ),
      ),
    );
  }
}

// ── 记忆碎片查看弹窗 ─────────────────────────────────────────────────────────

class _MemoryFactsDialog extends StatefulWidget {
  const _MemoryFactsDialog();

  @override
  State<_MemoryFactsDialog> createState() => _MemoryFactsDialogState();
}

class _MemoryFactsDialogState extends State<_MemoryFactsDialog> {
  List<Map<String, dynamic>> _facts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadFacts();
  }

  Future<void> _loadFacts() async {
    try {
      final facts = await DbHelper.instance.getAllMemoryFacts();
      if (mounted) {
        setState(() {
          _facts = facts;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.psychology, color: Colors.deepPurple.shade400, size: 20),
          const SizedBox(width: 8),
          const Text('长期记忆碎片', style: TextStyle(fontSize: 16)),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _facts.isEmpty
                ? Center(
                    child: Text(
                      '暂无记忆碎片\n请先进行长期记忆整理',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade500),
                    ),
                  )
                : ListView.separated(
                    itemCount: _facts.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final fact = _facts[index];
                      final factType =
                          fact['fact_type'] as String? ?? 'other';
                      final content =
                          fact['fact_content'] as String? ?? '';
                      final score =
                          (fact['importance_score'] as num?)?.toDouble() ??
                              0.5;
                      return ListTile(
                        dense: true,
                        leading: _factTypeIcon(factType),
                        title: Text(content,
                            style: const TextStyle(fontSize: 13)),
                        trailing: _importanceIndicator(score),
                      );
                    },
                  ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _factTypeIcon(String factType) {
    final Map<String, (IconData, Color)> typeMap = {
      'habit': (Icons.schedule, Colors.blue),
      'preference': (Icons.favorite, Colors.pink),
      'relationship': (Icons.people, Colors.orange),
      'event': (Icons.event_note, Colors.teal),
      'other': (Icons.info_outline, Colors.grey),
    };
    final (IconData icon, Color color) =
        typeMap[factType] ?? (Icons.circle, Colors.grey);
    return CircleAvatar(
      radius: 14,
      backgroundColor: color.withValues(alpha: 0.15),
      child: Icon(icon, size: 14, color: color),
    );
  }

  Widget _importanceIndicator(double score) {
    final color = score >= 0.8
        ? Colors.red
        : score >= 0.6
            ? Colors.orange
            : Colors.grey;
    return Text(
      '${(score * 100).toInt()}%',
      style:
          TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.bold),
    );
  }
}
