// 备份「按类别取舍」的守卫（2026-09-22 需求 3）。
//
// 背景：备份导入原本是纯覆盖式的"整机快照还原"，而需求 3 要的是"只导入搜索词"
// 的范本文件 —— 若照旧覆盖，导入一份只含 searchHistory 的范本会把设置、收藏的
// 合集、续读点一起清空。改法是把判据从"值空不空"换成"data 里字段存不存在"：
// 完整备份六个字段齐全（语义仍是快照），手写的局部文件只带一个字段（只动这一类）。
//
// 这层语义一旦被改回"空值也覆盖"，用户导入搜索词范本就会静默丢数据，
// 所以用测试钉住它，顺便验证随仓库发布的那份范本真的能被解析。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_reader/data/backup.dart';

String _payloadText(Map<String, dynamic> data) => jsonEncode({
      'schema': 1,
      'app': 'simple-reader',
      'platform': 'android',
      'appVersion': '1.9.5',
      'exportedAt': 1790078400000,
      'data': data,
    });

void main() {
  test('导出的完整备份被判为整机快照：六个类别齐全', () {
    final payload = BackupService.parse(_payloadText({
      'settings': <String, dynamic>{'themeMode': 'dark'},
      'searchHistory': <String>['关键词'],
      'readPositions': <String, dynamic>{},
      'favouriteCollections': <String, dynamic>{},
      'voteOverlay': <String, dynamic>{},
      'contentCache': <dynamic>[],
    }));

    expect(payload, isNotNull);
    expect(payload!.isFullSnapshot, isTrue,
        reason: '导出文件必须走"整机快照还原"语义');
    expect(payload.includedLabels.length, BackupService.sectionLabels.length);
    // 空值也算"这一类要覆盖" —— 判据是字段存在，不是值非空。
    expect(payload.provided, contains('favouriteCollections'));
  });

  test('只带 searchHistory 的局部文件：不算快照，且只认这一类', () {
    final payload = BackupService.parse(_payloadText({
      // 下划线开头的未知键是范本里的说明文字，不参与类别判定。
      '_说明': <String, dynamic>{'这是什么': '搜索词导入范本'},
      'searchHistory': <String>['关键词甲', '关键词乙'],
    }));

    expect(payload, isNotNull);
    expect(payload!.isFullSnapshot, isFalse);
    expect(payload.provided, <String>{'searchHistory'});
    expect(payload.includedLabels, <String>['搜索历史']);
    expect(payload.historyCount, 2);
    // 其余类别解析成空且"未提供"，导入时不该被动过。
    expect(payload.provided, isNot(contains('settings')));
    expect(payload.provided, isNot(contains('favouriteCollections')));
    expect(payload.provided, isNot(contains('contentCache')));
  });

  test('拒绝非本应用备份与更高 schema', () {
    expect(
      BackupService.parse(jsonEncode({
        'schema': 1,
        'app': 'other-app',
        'data': <String, dynamic>{},
      })),
      isNull,
    );
    expect(
      BackupService.parse(jsonEncode({
        'schema': 2,
        'app': 'simple-reader',
        'data': <String, dynamic>{},
      })),
      isNull,
      reason: 'schema 高于本端时要拒绝，而不是按老规则猜着导入',
    );
    expect(BackupService.parse('not json at all'), isNull);
  });

  test('随仓库发布的搜索词范本可被解析且只带搜索历史', () {
    // 测试的工作目录是 app/，仓库根在其上一级。
    final file = File('../范本/搜索词导入范本.json');
    expect(file.existsSync(), isTrue, reason: '搜索词范本应随仓库提交');

    final payload = BackupService.parse(file.readAsStringSync());
    expect(payload, isNotNull, reason: '范本必须能被本应用导入');
    expect(payload!.provided, <String>{'searchHistory'},
        reason: '范本带多余类别会在导入时覆盖掉用户的其它数据');
    expect(payload.isFullSnapshot, isFalse);
    expect(payload.searchHistory, isNotEmpty);
  });
}
