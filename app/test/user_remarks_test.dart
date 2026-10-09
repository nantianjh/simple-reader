// 用户备注（2026-09-23 需求 3）的两条硬约束守卫：
//
// 1. **展示口径**：设了备注就显示「本名（备注名）」—— 这是用户唯一能感知的
//    规则，任何一处拼错（比如写成「备注名（本名）」或漏掉括号）都是需求没做到；
// 2. **备份往返**：备注必须随导出文件走，且只带 searchHistory 的局部文件
//    不能把本机备注连坐清空（判据是"字段存不存在"，与其它类别同口径）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_reader/data/backup.dart';
import 'package:simple_reader/data/user_remarks.dart';

String _payloadText(Map<String, dynamic> data) => jsonEncode({
      'schema': 1,
      'app': 'simple-reader',
      'platform': 'android',
      'appVersion': '1.9.7',
      'exportedAt': 1790078400000,
      'data': data,
    });

void main() {
  group('展示口径「本名（备注名）」', () {
    test('有备注 → 本名（备注名）', () {
      expect(UserRemark.compose('张三', '同事老王'), '张三（同事老王）');
    });

    test('没有备注 → 原样显示本名', () {
      expect(UserRemark.compose('张三', ''), '张三');
      expect(UserRemark.compose('张三', '   '), '张三');
    });

    test('本名缺失 → 只显示备注名（不出现空括号）', () {
      expect(UserRemark.compose('', '同事老王'), '同事老王');
    });

    test('首尾空白不进入展示结果', () {
      expect(UserRemark.compose(' 张三 ', ' 老王 '), '张三（老王）');
    });
  });

  group('备注条目解析', () {
    test('remark 为空的记录不算备注', () {
      expect(
        UserRemark.fromJson('u1', <String, dynamic>{'nickname': '张三'}),
        isNull,
      );
      expect(
        UserRemark.fromJson('u1',
            <String, dynamic>{'nickname': '张三', 'remark': '   '}),
        isNull,
      );
      expect(UserRemark.fromJson('', <String, dynamic>{'remark': '老王'}), isNull);
    });

    test('正常记录可解析', () {
      final r = UserRemark.fromJson('u1', <String, dynamic>{
        'nickname': '张三',
        'remark': '老王',
        'updatedAt': 1790078400000,
      });
      expect(r, isNotNull);
      expect(r!.userId, 'u1');
      expect(r.nickname, '张三');
      expect(r.remark, '老王');
      expect(r.updatedAt.millisecondsSinceEpoch, 1790078400000);
    });
  });

  group('备份里的用户备注', () {
    test('导出文件里的备注能被解析出来（并计入数量）', () {
      final payload = BackupService.parse(_payloadText({
        'userRemarks': <String, dynamic>{
          'items': <String, dynamic>{
            'u1': <String, dynamic>{'nickname': '张三', 'remark': '老王'},
            'u2': <String, dynamic>{'nickname': '李四', 'remark': '同学'},
          },
        },
      }));

      expect(payload, isNotNull);
      expect(payload!.provided, contains('userRemarks'));
      expect(payload.remarkCount, 2);
      expect(payload.includedLabels, contains('用户备注'));
    });

    test('只带搜索词的局部文件不带备注类别 —— 导入时不能动本机备注', () {
      final payload = BackupService.parse(_payloadText({
        'searchHistory': <String>['关键词'],
      }));

      expect(payload, isNotNull);
      expect(payload!.provided, isNot(contains('userRemarks')));
      expect(payload.remarkCount, 0);
      expect(payload.isFullSnapshot, isFalse);
    });
  });
}
