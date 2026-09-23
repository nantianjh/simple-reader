// 版本一致性守卫：AppInfo.version 是手工维护的常量（零依赖约定下不引
// package_info），注释承诺「与 pubspec.yaml 的 version: 前缀手工保持一致」。
// v1.9.2 起曾连续三个版本漏更新（实机启动日志横幅/备份 appVersion 一直
// 停在 1.9.1），这里用测试把这个承诺固化 —— pubspec 一改而常量不改即红。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_reader/app_info.dart';

void main() {
  test('AppInfo.version 与 pubspec.yaml 版本前缀一致', () {
    final text = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(text);
    expect(m, isNotNull, reason: 'pubspec.yaml 缺少 version: 行');
    final pubspecVersion = m!.group(1)!;
    // version: "1.9.4+29" 的前缀（不含 build number）应与常量一致。
    final prefix = pubspecVersion.split('+').first;
    expect(AppInfo.version, prefix,
        reason: 'AppInfo.version 未随 pubspec 版本顺延，'
            '启动日志横幅与备份文件 appVersion 会暴露旧版本号');
  });
}
