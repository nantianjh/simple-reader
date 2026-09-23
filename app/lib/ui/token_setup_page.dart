import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/jwt_utils.dart';
import '../data/settings.dart';
import '../platform/native_bridge.dart';
import '../state/app_scope.dart';
import '../state/app_state.dart';
import '../util/app_log.dart';
import '../util/format.dart';
import 'theme.dart';
import 'widgets/brightness_aware.dart';

/// 凭证配置入口。
///
/// 三条路径并存：
/// * 「自动检测」—— 进入本页时后台离屏读取官方网页端的登录态，
///   已登录则自动提取凭证进入主界面（首次与再次进入同样生效）；
/// * 「账号登录」—— 应用内 WebView 打开官方网页版，用户手动完成手机号 +
///   短信验证码登录后，原生自动把凭证回传并关闭登录页，校验通过即进入
///   主界面；
/// * 「自定义 Token」—— 手工粘贴（长期保留的兜底路径）。
///
/// 交互口径（需求调整）：首次进入只**提示两条路**（账号登录 / 自定义
/// Token），等用户自己选；不再把「粘贴 Token」输入卡默认铺开，也就不会
/// 在"本机没有凭证"时自动把用户推进手工输入模式。
class TokenSetupPage extends StatefulWidget {
  const TokenSetupPage({super.key, this.onCompleted});

  /// 配置成功后的回调，由宿主决定跳转。
  final VoidCallback? onCompleted;

  @override
  State<TokenSetupPage> createState() => _TokenSetupPageState();
}

/// 本页上用户选择的凭证配置方式。
enum _CredMode {
  /// 应用内登录官方网页版，凭证由原生回传。
  webLogin,

  /// 手工粘贴网页端 token。
  manual,
}

class _TokenSetupPageState extends State<TokenSetupPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  JwtInfo? _preview;
  String? _inputError;
  bool _submitting = false;
  bool _obscure = true;

  /// 当前选中的配置方式。null = 还没选：此时不显示 token 输入卡，
  /// 只展示两种方式与一句提示（见 [_modeHint]）。
  _CredMode? _mode;

  @override
  void initState() {
    super.initState();
    final existing = AppScope.read(context).token;
    if (existing != null && existing.isNotEmpty) {
      _controller.text = existing;
      _preview = parseJwt(existing);
      // 本机已有凭证（换凭证 / 修复失效凭证的场景）：直接进粘贴模式，
      // 省掉一次选择 —— 用户来这里就是要替换它。
      _mode = _CredMode.manual;
    }
    _controller.addListener(_onChanged);
    // 进入凭证页先离屏检测一次网页端登录态：官方 Web 端若已登录
    // （此前登录过或每日刷新过），直接提取凭证自动进入阅读模式，
    // 全程不打扰用户；检测不到则静默复位，页面回到手工配置。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _autoDetectWebLogin();
    });
  }

  /// 静默检测网页端登录态（非首次运行与首次运行同样适用）。
  ///
  /// 只在「本地没有可用凭证」时触发：已有 token 的换凭证场景不打扰。
  /// 检测由原生离屏 WebView 完成，结果走 main.dart 的统一回调；
  /// 原生没接住（返回 false）时在此复位等待态，其余路径由回调收口。
  Future<void> _autoDetectWebLogin() async {
    final app = AppScope.read(context);
    final noUsableToken = app.status == AuthStatus.missing ||
        (app.status == AuthStatus.invalid && app.token == null);
    if (!noUsableToken) return;
    if (app.webPeeking || app.webLoginWaiting) return;

    app.setWebPeeking(true);
    log.i(LogTag.auth, '进入凭证页，离屏检测网页端登录态…');
    final started = await NativeBridge.instance.peekWebLogin();
    if (!started && mounted) {
      app.setWebPeeking(false);
      log.w(LogTag.auth, '离屏检测未能启动（原生未接住），回到手工配置');
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() {
    final text = _controller.text.trim();
    final info = text.isEmpty ? null : parseJwt(text);
    setState(() {
      _preview = info;
      _inputError = null;
    });
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      _showSnack('剪贴板里没有文本');
      return;
    }
    _controller.text = text;
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
  }

  /// 打开应用内登录页（原生 WebView 加载官方 Web 端）。
  ///
  /// 凭证回传后由 main.dart 的全局回调统一处理：
  /// 校验 → 保存 → AppState.status 变 ready → RootShell 自动切主界面。
  /// 本页只负责发起与展示等待态。
  Future<void> _startWebLogin() async {
    final app = AppScope.read(context);
    final ok = await NativeBridge.instance.openLogin();
    if (!mounted) return;
    if (!ok) {
      _showSnack('无法打开内置浏览器页面');
      return;
    }
    app.setWebLoginWaiting(true);
  }

  /// 选择「账号登录」：置位模式后立即拉起登录页。
  ///
  /// 原生没接住（或启动失败）时退回未选择状态 —— 否则页面会停在一个
  /// 没有反馈的"等待登录"状态上，用户不知道下一步该干什么。
  Future<void> _chooseWebLogin() async {
    setState(() => _mode = _CredMode.webLogin);
    await _startWebLogin();
    if (!mounted) return;
    if (!AppScope.read(context).webLoginWaiting) {
      setState(() => _mode = null);
    }
  }

  /// 选择「自定义 Token」：铺开输入卡并把焦点交给它，方便直接粘贴。
  void _chooseManual() {
    setState(() => _mode = _CredMode.manual);
    // 输入卡在本次 setState 后才挂载，焦点要等下一帧再请求。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _inputError = '请先粘贴 token');
      return;
    }

    final info = parseJwt(text);
    if (!info.valid) {
      setState(() => _inputError = info.reason ?? 'token 格式不正确');
      return;
    }
    if (info.isExpired) {
      setState(() => _inputError = '该 token 已过期，请重新获取');
      return;
    }

    setState(() => _submitting = true);
    final app = AppScope.read(context);
    final ok = await app.loginWithToken(text);
    if (!mounted) return;
    setState(() => _submitting = false);

    if (ok) {
      _showSnack('Token 校验通过');
      widget.onCompleted?.call();
    } else {
      setState(() => _inputError = app.errorMessage ?? '校验失败，请确认 token 是否有效');
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    // 包一层亮度依赖：本页配色全是静态语义色，不重建就会停在旧主题。
    return BrightnessAware(builder: (context, _) => _contents());
  }

  Widget _contents() {
    final app = AppScope.of(context);
    final verifying = app.status == AuthStatus.verifying || _submitting;
    // 首次安装（还没完成过登录）时多一层欢迎引导，告诉用户这是什么软件、
    // 接下来会发生什么；老用户（换凭证场景）不需要这层。
    final firstRun = !AppSettings.instance.firstRunDone;

    return Scaffold(
      backgroundColor: AppTheme.pageBackground,
      appBar: AppBar(
        title: Text(firstRun ? '欢迎使用 Simple阅读' : '配置访问凭证'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            if (firstRun) ...[
              _welcome(),
              const SizedBox(height: 16),
            ],
            _intro(),
            const SizedBox(height: 16),
            _modeSelector(firstRun),
            const SizedBox(height: 16),
            // 需求调整：只有用户主动选了「自定义 Token」才铺开输入卡，
            // 否则停在"选一条路"的提示上 —— 不再默认进入输入 token 模式。
            if (_mode == _CredMode.manual)
              _tokenCard(verifying, app)
            else
              _modeHint(),
            const SizedBox(height: 16),
            _helpCard(),
          ],
        ),
      ),
    );
  }

  /// 尚未选择方式时的提示条：把两条路一次讲清，等用户自己点。
  Widget _modeHint() {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: BoxDecoration(
        color: AppTheme.infoBackground,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.touch_app_outlined, size: 15, color: AppTheme.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '选一种方式开始：点「账号登录」在应用内登录网页版，凭证会自动带回；'
              '或点「自定义 Token」，把从网页端取出的凭证粘贴进来。',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: AppTheme.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 欢迎引导

  /// 首次安装的欢迎卡：一句话讲清软件定位与登录后的流程。
  Widget _welcome() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.accent.withValues(alpha: 0.10),
            AppTheme.accent.withValues(alpha: 0.03),
          ],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.25), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '三步开始使用',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppTheme.inkPrimary,
            ),
          ),
          const SizedBox(height: 10),
          _welcomeStep('1', '登录账号',
              '点下方「账号登录」，在打开的页面里完成登录，凭证自动带回（推荐）。'),
          _welcomeStep('2', '进入主界面',
              '登录成功后直接进入检索与阅读界面。'),
          _welcomeStep('3', '开始探索',
              '搜索内容、收藏动态、订阅合集；看过的内容会缓存，支持离线续读。'),
          const SizedBox(height: 6),
          Text(
            '不想登录网页？也可以从电脑浏览器取出 Token 手工粘贴（见底部帮助）。',
            style: TextStyle(
              fontSize: 11.5,
              color: AppTheme.inkTertiary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _welcomeStep(String index, String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.accent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Text(
              index,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.accent,
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$title：',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.inkPrimary,
                    ),
                  ),
                  TextSpan(
                    text: body,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppTheme.inkSecondary,
                      height: 1.55,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 头部

  Widget _intro() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.divider, width: 0.6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppTheme.accent.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(Icons.key_rounded, size: 20, color: AppTheme.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '需要一个访问凭证才能检索内容',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.inkPrimary,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '凭证只保存在本机应用私有目录，不会上传到任何第三方服务。',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.inkSecondary,
                    height: 1.55,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 方案选择

  Widget _modeSelector(bool firstRun) {
    final app = AppScope.of(context);
    final detecting = app.webPeeking || app.webLoginWaiting;
    final manualActive = _mode == _CredMode.manual && !detecting;
    final webActive = _mode == _CredMode.webLogin || detecting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            '凭证方式',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.inkSecondary,
            ),
          ),
        ),
        Row(
          children: [
            Expanded(
              child: _modeTile(
                title: '自定义 Token',
                subtitle: '从网页端获取',
                active: manualActive,
                enabled: !detecting,
                icon: Icons.content_paste_rounded,
                onTap: detecting ? null : _chooseManual,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _modeTile(
                title: app.webPeeking
                    ? '正在检测网页登录…'
                    : (app.webLoginWaiting ? '正在等待网页登录…' : '账号登录'),
                subtitle: app.webPeeking
                    ? '检测到网页端已登录会自动进入应用'
                    : (app.webLoginWaiting
                        ? '在打开的页面完成登录后会自动进入应用'
                        : '应用内登录网页版，自动带回凭证'),
                active: webActive,
                enabled: !detecting,
                icon: Icons.person_outline_rounded,
                // 首次使用把账号登录标成推荐路径：不用碰开发者工具，
                // 登录后凭证自动带回，是三条路里最顺的一条。
                badge: firstRun && !detecting && _mode == null ? '推荐' : null,
                trailing: detecting
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: detecting ? null : _chooseWebLogin,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _modeTile({
    required String title,
    required String subtitle,
    required bool active,
    required bool enabled,
    required IconData icon,
    VoidCallback? onTap,
    Widget? trailing,
    String? badge,
  }) {
    final borderColor = active ? AppTheme.accent : AppTheme.divider;
    final bg = active ? AppTheme.accent.withValues(alpha: 0.05) : AppTheme.cardBackground;
    final fg = enabled ? AppTheme.inkPrimary : AppTheme.inkTertiary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: borderColor,
            width: active ? 1.4 : 0.6,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 19, color: active ? AppTheme.accent : fg),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: active ? AppTheme.accent : fg,
                          ),
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 0.5),
                          decoration: BoxDecoration(
                            color: AppTheme.accent,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            badge,
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                      if (active && trailing == null && badge == null) ...[
                        const SizedBox(width: 5),
                        Icon(Icons.check_circle_rounded,
                            size: 13, color: AppTheme.accent),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppTheme.inkTertiary,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 6),
              trailing,
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 输入卡

  Widget _tokenCard(bool verifying, AppState app) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.divider, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '粘贴 Token',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.inkPrimary,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _pasteFromClipboard,
                icon: const Icon(Icons.content_paste_go_rounded, size: 16),
                label: const Text('粘贴', style: TextStyle(fontSize: 13)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _controller,
            focusNode: _focus,
            maxLines: 4,
            minLines: 3,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(
              fontSize: 12.5,
              fontFamily: 'monospace',
              height: 1.5,
            ),
            decoration: InputDecoration(
              hintText: 'eyJhbGciOiJIUzI1NiJ9...',
              errorText: _inputError,
              suffixIcon: IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 19,
                  color: AppTheme.inkTertiary,
                ),
                tooltip: _obscure ? '显示' : '隐藏',
              ),
            ),
          ),
          if (_preview != null) ...[
            const SizedBox(height: 10),
            _previewCard(_preview!),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: verifying ? null : _submit,
              child: verifying
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(width: 10),
                        Text('正在校验…'),
                      ],
                    )
                  : const Text('保存并验证'),
            ),
          ),
          if (app.status == AuthStatus.invalid && app.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 15, color: AppTheme.danger),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      app.errorMessage!,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: AppTheme.danger,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Token 本地解析预览。填写时即时给出结构化反馈，减少往返。
  Widget _previewCard(JwtInfo info) {
    if (!info.valid) {
      return _row(
        icon: Icons.error_outline_rounded,
        color: AppTheme.danger,
        title: '格式不正确',
        value: info.reason ?? '无法解析',
      );
    }
    if (info.isExpired) {
      return _row(
        icon: Icons.hourglass_disabled_rounded,
        color: AppTheme.danger,
        title: '已过期',
        value: formatDateTime(info.expiresAt),
      );
    }

    final remaining = info.remaining;
    final soon = info.isExpiringSoon;
    final hint = soon ? AppTheme.warning : AppTheme.success;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      decoration: BoxDecoration(
        color: hint.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: hint.withValues(alpha: 0.25),
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                soon ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                size: 15,
                color: hint,
              ),
              const SizedBox(width: 6),
              Text(
                soon ? '格式正确，但即将过期' : '格式正确',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: hint,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          if (info.userId != null)
            _kv('用户 ID', info.userId!),
          if (remaining != null) _kv('剩余有效期', humanDuration(remaining)),
          if (info.expiresAt != null)
            _kv('到期时间', formatDateTime(info.expiresAt)),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 68,
            child: Text(
              k,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.inkTertiary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.inkSecondary,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required Color color,
    required String title,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 0.6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            '$title：',
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12.5,
                color: AppTheme.inkSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 帮助卡

  Widget _helpCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.divider, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline_rounded,
                  size: 16, color: AppTheme.inkSecondary),
              const SizedBox(width: 6),
              Text(
                '怎么获取 Token',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.inkPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _step('1', '在电脑浏览器打开 simple.imsummer.cn 并登录你的账号'),
          _step('2', '按 F12 打开开发者工具，切到 Network（网络）面板'),
          _step('3', '刷新页面，点开任意一条请求，找到请求头里的 Authorization'),
          _step('4', '复制它的完整值（一长串 eyJ 开头的字符串），粘贴到上方'),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.warningBackground,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.warningBorder, width: 0.6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 15, color: AppTheme.warning),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'Token 等同于你的账号凭证，有效期约 30 天，请勿分享给他人或提交到代码仓库。'
                    '过期后在网页版重新登录即可再取一次。',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.warning,
                      height: 1.55,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _step(String index, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 17,
            height: 17,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.accent.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Text(
              index,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.accent,
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                color: AppTheme.inkSecondary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
