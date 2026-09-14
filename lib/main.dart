import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';
import 'screens/chat_screen.dart';
import 'services/proactive_message_service.dart';

// ==========================================
// 后台任务入口（workmanager 要求顶层函数）
// 阶段三 F-013：主动消息后台调度
// ==========================================

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == 'proactiveCheck') {
      await ProactiveMessageService.backgroundCheck();
    }
    return Future.value(true);
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化本地通知插件（阶段三 F-014）
  final plugin = FlutterLocalNotificationsPlugin();
  const initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await plugin.initialize(initSettings);

  // 初始化 workmanager 并注册每2小时的周期性检查任务（阶段三 F-013）
  await Workmanager().initialize(callbackDispatcher);
  await Workmanager().registerPeriodicTask(
    'proactiveCheckTask',
    'proactiveCheck',
    frequency: const Duration(hours: 2),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    constraints: Constraints(networkType: NetworkType.notRequired),
  );

  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '怀念',
      theme: ThemeData(
        // V6.0：QQ 蓝主题
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF12B7F5)),
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}
