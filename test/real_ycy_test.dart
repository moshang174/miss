// 集成测试：用 D:\ycy 四份真实聊天记录验证导入管线（仅在本机存在该目录时运行）
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huainian/services/import_service.dart';

void main() {
  const paths = [
    r'D:\ycy\番外1.txt',
    r'D:\ycy\番外2.txt',
    r'D:\ycy\第一章.txt',
    r'D:\ycy\第二章.txt',
  ];
  final allExist = paths.every((p) => File(p).existsSync());

  test('真实聊天记录四份合并导入', () async {
    final result = await ImportService().parseFiles([
      r'D:\ycy\番外1.txt',
      r'D:\ycy\番外2.txt',
      r'D:\ycy\第一章.txt',
      r'D:\ycy\第二章.txt',
    ]);
    debugPrint('文件数: ${result.fileCount}');
    debugPrint('总字符: ${result.totalChars}');
    debugPrint('切片字符: ${result.analysisSlice.length}');
    debugPrint('是否采样: ${result.isSampled}');
    debugPrint('切片前200字: ${result.analysisSlice.substring(0, 200)}');
    debugPrint('切片后200字: ${result.analysisSlice.substring(result.analysisSlice.length - 200)}');
    expect(result.fileCount, 4);
    expect(result.analysisSlice.isNotEmpty, isTrue);
    // 切片含最早的番外1开头与最新的第二章结尾（首尾均被覆盖）
    expect(result.analysisSlice.contains('莫西莫西'), isTrue);
    expect(result.analysisSlice.contains('我愿意听'), isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)), skip: !allExist);
}
