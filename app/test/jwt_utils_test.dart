import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_reader/auth/jwt_utils.dart';

/// 构造一个测试用 JWT（只做结构拼装，不涉及签名）。
String makeJwt(Map<String, dynamic> payload) {
  String seg(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${seg({'alg': 'HS256', 'typ': 'JWT'})}.${seg(payload)}.sig';
}

void main() {
  group('parseJwt', () {
    test('解析合法 token 的 user_id 与 exp', () {
      final exp = DateTime.now().add(const Duration(days: 30));
      final token = makeJwt({
        'user_id': '15e75816-0000-0000-0000-000000000000',
        'exp': exp.millisecondsSinceEpoch ~/ 1000,
      });

      final info = parseJwt(token);

      expect(info.valid, isTrue);
      expect(info.userId, '15e75816-0000-0000-0000-000000000000');
      expect(info.isExpired, isFalse);
      expect(info.expiresAt!.difference(exp).inSeconds.abs(), lessThan(2));
    });

    test('识别已过期的 token', () {
      final token = makeJwt({
        'user_id': 'u1',
        'exp': DateTime.now()
                .subtract(const Duration(days: 1))
                .millisecondsSinceEpoch ~/
            1000,
      });

      final info = parseJwt(token);

      expect(info.valid, isTrue);
      expect(info.isExpired, isTrue);
      expect(info.remaining!.isNegative, isTrue);
    });

    test('拒绝非三段结构', () {
      expect(parseJwt('not-a-jwt').valid, isFalse);
      expect(parseJwt('a.b').valid, isFalse);
      expect(parseJwt('').valid, isFalse);
    });

    test('兼容用户误带的 Bearer 前缀', () {
      final token = makeJwt({
        'user_id': 'u2',
        'exp': DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000,
      });

      final info = parseJwt('Bearer $token');

      expect(info.valid, isTrue);
      expect(info.userId, 'u2');
    });

    test('isExpiringSoon 在 7 天阈值内为真', () {
      final soon = parseJwt(makeJwt({
        'exp': DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch ~/ 1000,
      }));
      final later = parseJwt(makeJwt({
        'exp': DateTime.now().add(const Duration(days: 20)).millisecondsSinceEpoch ~/ 1000,
      }));

      expect(soon.isExpiringSoon, isTrue);
      expect(later.isExpiringSoon, isFalse);
    });
  });
}
