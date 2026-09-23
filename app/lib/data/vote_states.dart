/// 点赞「表态」状态表 —— 点赞可以带一个具体态度，服务端叫 `vote_type`。
///
/// 依据《点赞状态承载能力-探查报告.md》（2026-09-22 实测）：
///
/// * 只有 `POST api/v3/votes` 认 `vote_type`；`api/v2/votes` 会**静默丢弃**
///   这个字段（写入矩阵第 2 步）—— 这是最容易踩的坑。
/// * `vote_type` 是**服务端白名单**，非法值 400
///   `{"error":"vote_type does not have a valid value"}`，且**不改动已有状态**；
///   大小写与空格敏感。
/// * 那句带表情的文案（"🫂轻轻安慰了你"）由**服务端下发**
///   （`vote_type_name`），客户端包里搜不到 —— 所以下面这张表是本机维护的
///   **副本**，不是权威来源。
///
/// 维护约定：
///
/// * [VoteState.id] 必须与实测过的服务端值**逐字一致**（大小写、空格都敏感）；
/// * 表里没有的值不要猜：服务端可能增删。收到 400 就当"这个状态暂时送不
///   出去"提示，**不要**退化成普通赞（退化了用户看不出自己送错了什么）；
/// * 读侧拿不到"我这条是什么状态"（动态对象只暴露 `is_voted` 布尔），要显示
///   得每帖多发一个请求翻 `v3/votes` 列表，代价不值 —— 本机只记自己刚送出的
///   那个（见 `VoteOverlay`），因此表里的 [VoteState.short] 是按钮回显要用的
///   短名，服务端文案太长塞不进按钮。
library;

/// 一个可送出的表态。
class VoteState {
  const VoteState({
    required this.id,
    required this.emoji,
    required this.text,
    required this.short,
  });

  /// 写入用的 `vote_type` 原值。
  final String id;

  /// 服务端下发文案里的表情符号。
  final String emoji;

  /// 服务端下发文案去掉表情后的部分（照抄，不润色）。
  final String text;

  /// 按钮上回显用的短名（服务端文案太长）。
  final String short;

  /// 服务端下发的那整句文案，例如 `🫂轻轻安慰了你`。
  String get caption => '$emoji$text';
}

/// 可选表态全集与查询。
class VoteStates {
  VoteStates._();

  /// 默认态：普通赞。点赞但没带态度时服务端记的就是它。
  ///
  /// ⚠️ 它不是"可选状态"，别当参数往外传（白名单里未必有这个字面值）。
  /// 要回到普通赞就是不传 `vote_type` —— 实测 `POST v3/votes` 不带参数会
  /// **复位**成默认态（写入矩阵第 5 步）。
  static const String plain = 'unknown';

  /// 可送出的表态。顺序即展示顺序。
  ///
  /// 不含 [plain]；也不含 `laugh`（😂被你逗笑了）—— 本机刻意不做这个入口。
  static const List<VoteState> all = [
    VoteState(
        id: 'understanding', emoji: '🤝', text: '表示理解你的感受', short: '理解'),
    VoteState(id: 'support', emoji: '🌱', text: '向你表达了支持', short: '支持'),
    VoteState(
        id: 'encouragement', emoji: '💪', text: '给你加油鼓劲了', short: '加油'),
    VoteState(id: 'comfort', emoji: '🫂', text: '轻轻安慰了你', short: '安慰'),
    VoteState(id: 'blessing', emoji: '🌤️', text: '向你表达了祝福', short: '祝福'),
    VoteState(id: 'resonance', emoji: '🤍', text: '共鸣了你的动态', short: '共鸣'),
    VoteState(id: 'accompany', emoji: '🌙', text: '正在静静陪伴你', short: '陪伴'),
    VoteState(id: 'warmth', emoji: '🌸', text: '被你温暖了', short: '温暖'),
    VoteState(id: 'see', emoji: '✨', text: '看见了你的表达', short: '看见'),
    VoteState(id: 'gratitude', emoji: '💐', text: '谢谢了你', short: '感谢'),
  ];

  /// 按 `vote_type` 找表态。
  ///
  /// 默认态 [plain]、空值、表外的值一律返回 null —— 调用方按"没有态度
  /// （普通赞）"处理即可，不需要自己判空字符串。
  static VoteState? byId(String? id) {
    if (id == null || id.isEmpty || id == plain) return null;
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }
}
