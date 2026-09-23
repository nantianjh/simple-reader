// 续读存档「血脉」回归测试：游标链任一槽位（≥1）分叉 = 从第 1 页重新开始
// 的新抓取，旧链 / 旧缓存深度 / 旧已读线坐标必须整体作废。
//
// 背景（2026-09-21 实机日志复现）：同词再次提交强制联网重抓了 3 页，旧存档
// 却记着 29 页的游标链。旧合并逻辑「取更长的链」把新链丢了、深度也只增不减，
// 于是存档变成「新停留位置 + 旧寻址信息」：下次续读按旧游标寻址，第 1 页命中
// 被新抓覆盖的缓存文件（键固定含空游标），第 2..29 页命中旧缓存文件（键里
// 带着旧游标、文件仍在），拼出「新第 1 页 + 旧第 2..29 页」的混杂列表；且新
// 锚点在旧页里找不到，触发「续读锚点不在当前页，退回页首」。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_reader/data/reading_positions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const storeChannel = MethodChannel('cn.imsummer.simple_reader/store');

  setUp(() {
    // 存档落盘走自建 MethodChannel，测试里mock成空实现即可。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storeChannel, null);
  });

  const scope = 'test:lineage';

  /// 搭建旧存档：30 格游标链（模拟多天前一路抓到第 29 页），缓存深度 28
  /// （0 起），停留位置与已读线都在旧内容深处。
  Future<void> seedLegacyArchive() async {
    final old = List<String>.generate(30, (i) => i == 0 ? '' : 'old-c$i');
    await ReadingPositionStore.instance.record(
      scope,
      postId: 'old-anchor',
      index: 5,
      page: 28,
      offsetInPage: 2,
      keyword: 'ai',
      cursors: old,
    );
    await ReadingPositionStore.instance
        .saveCursors(scope, old, cachedDeepPage: 28);
    final pos = ReadingPositionStore.instance.get(scope)!;
    expect(pos.cursors.length, 30, reason: '前置条件：旧链已入档');
    expect(pos.cachedDeepPage, 28, reason: '前置条件：旧深度已入档');
    expect(pos.readPage, 28, reason: '前置条件：旧已读线已入档');
  }

  test('强制联网重抓：新血脉必须整体重建存档，旧链不得因更长而保留', () async {
    await ReadingPositionStore.instance.clear();
    await seedLegacyArchive();

    // 新会话第 1 页联网抓到新内容 → 只学到一个新游标（链长 2）。
    await ReadingPositionStore.instance
        .saveCursors(scope, const ['', 'new-c1'], cachedDeepPage: 0);
    var pos = ReadingPositionStore.instance.get(scope)!;
    expect(pos.cursors, const ['', 'new-c1'],
        reason: '血脉已变更：旧 30 格链必须作废，按新抓取重建');
    expect(pos.cachedDeepPage, 0,
        reason: '缓存深度必须随新血脉重建，不能保留旧的 29 页');
    expect(pos.readPage, -1, reason: '旧已读线坐标标在旧内容上，血脉变更时应归零');

    // 继续抓第 2、3 页：同血脉正常生长。
    await ReadingPositionStore.instance
        .saveCursors(scope, const ['', 'new-c1', 'new-c2'], cachedDeepPage: 1);
    await ReadingPositionStore.instance.saveCursors(
        scope, const ['', 'new-c1', 'new-c2', 'new-c3'],
        cachedDeepPage: 2);
    pos = ReadingPositionStore.instance.get(scope)!;
    expect(pos.cachedDeepPage, 2);

    // 采样停留位置：锚点停在新第 3 页末条，已读线从零抬起。
    await ReadingPositionStore.instance.record(
      scope,
      postId: 'new-anchor',
      index: 9,
      page: 2,
      offsetInPage: 9,
      keyword: 'ai',
      cursors: const ['', 'new-c1', 'new-c2', 'new-c3'],
    );
    pos = ReadingPositionStore.instance.get(scope)!;
    expect(pos.postId, 'new-anchor');
    expect(pos.page, 2);
    expect(pos.readPage, 2, reason: '新血脉的已读线从本次会话重新抬起');
    expect(pos.cursors[2], 'new-c2',
        reason: '下次续读第 3 页的请求游标必须来自新会话（命中新缓存页），'
            '而不是旧链的 old-c2（命中旧缓存页）');
  });

  test('同血脉的短链（续读会话回读缓存页）不得截断旧链、不得回退深度', () async {
    await ReadingPositionStore.instance.clear();
    await seedLegacyArchive();

    // 续读会话吸收 30 格链后重新读第 1 页（cacheOnly 命中），上报的链与
    // 存档同血脉、且长度只有 2 —— 必须按「更完整就吸收」保留整条链。
    await ReadingPositionStore.instance
        .saveCursors(scope, const ['', 'old-c1'], cachedDeepPage: 0);
    final pos = ReadingPositionStore.instance.get(scope)!;
    expect(pos.cursors.length, 30, reason: '同血脉：链必须保持完整，跳页寻址不能丢');
    expect(pos.cachedDeepPage, 28, reason: '同血脉：深度只增不减，缓存回读不缩小');
  });

  test('血脉在第 2 槽之后才分叉：同样整体重建（旧缓存过保留期被清后重抓）', () async {
    await ReadingPositionStore.instance.clear();
    await seedLegacyArchive();

    // 第 1 页命中旧缓存（槽 1 一致），第 2 页缓存已被清理 → 网络重抓出新
    // 内容 → 槽 2 分叉。
    await ReadingPositionStore.instance
        .saveCursors(scope, const ['', 'old-c1', 'fresh-c2'], cachedDeepPage: 1);
    final pos = ReadingPositionStore.instance.get(scope)!;
    expect(pos.cursors, const ['', 'old-c1', 'fresh-c2'],
        reason: '槽 2 分叉同样构成血脉变更，旧链第 3 格起全部作废');
    expect(pos.cachedDeepPage, 1);
    expect(pos.readPage, -1,
        reason: '旧已读线停在第 29 页（分叉页起内容已换），必须归零');
  });

  test('分叉槽位之前的页内容未变：其上的旧已读线保留', () async {
    await ReadingPositionStore.instance.clear();
    // 小存档：只有 1 页缓存（链 2 格），已读线停在第 1 页第 2 条。
    await ReadingPositionStore.instance.record(
      scope,
      postId: 'a1',
      index: 1,
      page: 0,
      offsetInPage: 1,
      keyword: 'ai',
      cursors: const ['', 'c1'],
    );
    await ReadingPositionStore.instance
        .saveCursors(scope, const ['', 'c1'], cachedDeepPage: 0);

    // 第 2 页缓存被清理后重抓出新内容 → 槽 2 分叉；第 1 页请求游标一致、
    // 内容未变，其上的已读线（0,1）必须保留。
    await ReadingPositionStore.instance
        .saveCursors(scope, const ['', 'c1', 'c2new'], cachedDeepPage: 1);
    final pos = ReadingPositionStore.instance.get(scope)!;
    expect(pos.cursors, const ['', 'c1', 'c2new']);
    expect(pos.readPage, 0, reason: '分叉槽位之前的页内容未变，旧已读线仍有效');
    expect(pos.readOffset, 1);
  });

  test('采样先于游标落盘：record 同样能识别血脉变更并重建（防御路径）', () async {
    await ReadingPositionStore.instance.clear();
    await seedLegacyArchive();

    await ReadingPositionStore.instance.record(
      scope,
      postId: 'new-anchor',
      index: 0,
      page: 2,
      offsetInPage: 4,
      keyword: 'ai',
      cursors: const ['', 'new-c1', 'new-c2', 'new-c3'],
    );
    final pos = ReadingPositionStore.instance.get(scope)!;
    expect(pos.cursors, const ['', 'new-c1', 'new-c2', 'new-c3']);
    expect(pos.cachedDeepPage, -1,
        reason: 'record 不知道本次会话的真实深度，血脉变更时置为未知，等 saveCursors 覆盖');
    expect(pos.readPage, 2, reason: '旧已读线归零后由本次采样重新抬起');
  });
}
