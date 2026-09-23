package cn.imsummer.simple_reader

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import io.flutter.plugin.common.MethodChannel

/**
 * 应用内浏览器容器（系统 WebView，不打包任何浏览器内核）。
 *
 * 三种模式：
 *
 * 1. `web`  —— 官方网页版：全屏加载 [WEB_HOME]，顶栏右侧提供「阅读模式」
 *              按钮，点击后通知 Flutter 切回主界面并关闭本页；
 *              页面加载完成时静默读取一次登录信息（若用户在网页里登录过，
 *              凭证会自动同步回本应用）。
 *
 * 2. `link` —— 链接模式（"在 Simple 中打开"、正文链接等）：容器内打开
 *              http(s) 页面；页面里的非 http(s) 导航（simple:// 深链、
 *              intent:// 等）转交系统唤起对应应用，与真实浏览器同口径。
 *              官方分享页因此能一键跳进官方 App 的对应动态页——唤起成功
 *              后本页作为跳板自动收掉；没有应用能接时留在页面里，走官方
 *              自己的回落（3 秒后进官方下载页）。
 *
 * 3. `auth` —— 应用内登录：同样加载官方 Web 端，用户在页面里完成
 *              手机号 + 短信验证码登录后，前端会把用户信息写入
 *              `localStorage["flutter.UserInfo"]`；本页在页面加载完成
 *              时先读一次（此前登录过则直接命中），并以 1.5s（20 次后
 *              放宽到 5s）轮询兜底，取到后立刻回传 Flutter 并自动关闭
 *              本页，Flutter 侧走既有的校验/保存链路，直接进入主界面。
 *              凭证的读取与解析统一在 [WebAuthProbe]（含键名兜底扫描）。
 *
 * 凭证读取要点（全部来自官方 Web 端 main.dart.js 静态分析，可复核）：
 *   - shared_preferences 的 Web 实现统一给 localStorage 键名加 `flutter.` 前缀；
 *   - 实际写入的键是 `flutter.UserInfo`（用户信息 JSON）；
 *   - Authorization 头取的是其中的 `token` 字段（不是 `auth_token`），
 *     两个候选都回传，由 Dart 侧用既有的 JWT 解析挑选。
 *
 * 安全约束：
 *   - 不使用 addJavascriptInterface，只用 evaluateJavascript 主动读；
 *   - 关闭文件/内容访问；UA 去掉 "; wv" 标记，与普通浏览器一致；
 *   - 网页版/登录模式只拦截非 http(s) 协议（simple:// 唤起、weixin:// 等），
 *     避免跳出；链接模式把非 http(s) 导航转交系统，且对 intent:// 解析
 *     结果做 Chrome 同款消毒（见 [launchExternal]）；
 *   - 登录流程零自动化：不代填、不代提交，验证码与密码均由用户手动输入。
 */
class BrowserActivity : Activity() {

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_MODE = "mode"
        const val EXTRA_TITLE = "title"

        const val MODE_AUTH = "auth"
        const val MODE_WEB = "web"
        const val MODE_LINK = "link"

        /** 与 native_bridge.dart 中的通道名保持一致。 */
        const val CHANNEL = "cn.imsummer.simple_reader/browser"

        /** 顶栏与分隔线配色，贴合应用的浅色主题。 */
        private const val COLOR_BAR_BG = "#FFFFFF"
        private const val COLOR_BAR_TEXT = "#3A3F47"
        private const val COLOR_ACCENT = "#2563EB"
        private const val COLOR_DIVIDER = "#E4E8EE"
        private const val COLOR_PAGE_BG = "#FFFFFF"
    }

    private var mode: String = MODE_WEB
    private var webView: WebView? = null
    private lateinit var actionBtn: TextView
    private val handler = Handler(Looper.getMainLooper())

    private var pollCount = 0
    private var deliveredAuth = false
    private var finished = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        mode = intent?.getStringExtra(EXTRA_MODE) ?: MODE_WEB
        val url = intent?.getStringExtra(EXTRA_URL)?.takeIf { it.isNotBlank() }
            ?: WebAuthProbe.WEB_HOME
        val title = intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }
            ?: if (mode == MODE_AUTH) "账号登录" else "官方网页版"

        val density = resources.displayMetrics.density
        fun dp(v: Int): Int = (v * density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor(COLOR_PAGE_BG))
        }

        // ------------------------------------------------------------- 顶栏
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(Color.parseColor(COLOR_BAR_BG))
            setPadding(dp(6), dp(6), dp(10), dp(6))
        }

        val backBtn = TextView(this).apply {
            text = "←"
            textSize = 21f
            setTextColor(Color.parseColor(COLOR_BAR_TEXT))
            gravity = Gravity.CENTER
            setPadding(dp(10), dp(6), dp(10), dp(6))
            setOnClickListener { onBackPressedInternal() }
        }
        bar.addView(
            backBtn,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        val titleView = TextView(this).apply {
            text = title
            textSize = 15.5f
            setTextColor(Color.parseColor(COLOR_BAR_TEXT))
            maxLines = 1
        }
        bar.addView(
            titleView,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
                .apply { marginStart = dp(6) }
        )

        actionBtn = TextView(this).apply {
            text = if (mode == MODE_AUTH) "完成" else "阅读模式"
            textSize = 14.5f
            setTextColor(Color.parseColor(COLOR_ACCENT))
            setPadding(dp(10), dp(6), dp(4), dp(6))
            setOnClickListener {
                if (mode == MODE_AUTH) confirmAuth() else exitToReading()
            }
        }
        bar.addView(
            actionBtn,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        root.addView(
            bar,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        val divider = View(this).apply {
            setBackgroundColor(Color.parseColor(COLOR_DIVIDER))
        }
        root.addView(
            divider,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(1))
        )

        // ------------------------------------------------------------ WebView
        val wv = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            // 去掉 WebView 专属标记，与普通浏览器 UA 保持一致。
            settings.userAgentString =
                settings.userAgentString.replace("; wv", "", ignoreCase = true)
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView,
                    request: WebResourceRequest
                ): Boolean {
                    val scheme = request.url.scheme?.lowercase()
                    // http(s) 一律在容器内打开。
                    if (scheme == "http" || scheme == "https") return false
                    // 网页版 / 登录模式：忽略非 http(s) 协议，避免被页面带跳出去。
                    if (mode != MODE_LINK) return true
                    // 链接模式：与真实浏览器同口径——自定义协议 / intent://
                    // 交给系统唤起对应应用（simple://sharePost → 官方 App）。
                    return launchExternal(request.url)
                }

                override fun onPageFinished(view: WebView, url: String) {
                    // 网页版：静默同步一次凭证；登录页：同样先读一次——
                    // 若此前已登录过（登录态留存），页面一加载完即可自动
                    // 回传并关闭，不必等轮询。
                    if (!deliveredAuth) readUser()
                }
            }
            webChromeClient = WebChromeClient()
        }

        // WebView 必须放在 FrameLayout 里，否则某些 ROM 上输入框聚焦时
        // 会被键盘顶出可视区（adjustResize 对顶层 WebView 不生效）。
        val webHolder = FrameLayout(this)
        webHolder.addView(
            wv,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )
        root.addView(
            webHolder,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f
            )
        )

        setContentView(root)
        webView = wv
        CookieManager.getInstance().setAcceptCookie(true)
        wv.loadUrl(url)

        if (mode == MODE_AUTH) schedulePoll(1200L)
    }

    // ------------------------------------------------------------ 凭证读取

    private fun schedulePoll(delayMs: Long) {
        handler.postDelayed({ pollOnce() }, delayMs)
    }

    private fun pollOnce() {
        if (finished || deliveredAuth) return
        if (webView == null) return
        pollCount++
        readUser()
        schedulePoll(if (pollCount < 20) 1500L else 5000L)
    }

    /** 读一次 localStorage 的登录信息（静默，读不到就等下一轮）。 */
    private fun readUser() {
        val wv = webView ?: return
        wv.evaluateJavascript(WebAuthProbe.JS) { raw ->
            val res = WebAuthProbe.parse(raw)
            if (res.found) deliver(res)
        }
    }

    /** 顶栏「完成」：登录流程的正常收口。 */
    private fun confirmAuth() {
        val wv = webView ?: return
        wv.evaluateJavascript(WebAuthProbe.JS) { raw ->
            val res = WebAuthProbe.parse(raw)
            if (res.found) {
                deliver(res)
            } else {
                Toast.makeText(
                    this@BrowserActivity,
                    "尚未检测到登录信息，请在页面完成登录后再点「完成」",
                    Toast.LENGTH_SHORT
                ).show()
            }
        }
    }

    /** 返回键 / 返回箭头：先读最后一次，拿得到就算成功，拿不到按取消收口。 */
    private fun onBackPressedInternal() {
        val wv = webView
        if (wv != null && wv.canGoBack()) {
            wv.goBack()
            return
        }
        if (mode == MODE_AUTH) {
            // 凭证已回传过：直接关闭，App 侧已在校验或已进入主界面。
            if (deliveredAuth) {
                finish()
                return
            }
            wv?.evaluateJavascript(WebAuthProbe.JS) { raw ->
                val res = WebAuthProbe.parse(raw)
                if (res.found) {
                    deliver(res)
                } else {
                    deliverCancel(res.keys, res.diag)
                }
            } ?: deliverCancel()
        } else {
            finish()
        }
    }

    private fun deliver(res: WebAuthProbe.Result) {
        if (deliveredAuth) return
        deliveredAuth = true
        sendToFlutter(
            "onAuthToken",
            mapOf(
                "found" to true,
                "token" to res.token,
                "authToken" to res.authToken,
                "mode" to mode,
            )
        )
        if (mode == MODE_AUTH) {
            // 凭证已回传：登录页立即自动关闭，回到应用内由 Dart 侧继续
            // 校验并进入主界面（阅读模式）。不再停留在网页版等用户手动
            // 返回——那是修复前的现象，用户会误以为登录没有生效。
            finish()
        }
    }

    private fun deliverCancel(keys: String = "", diag: String = "") {
        if (deliveredAuth) return
        deliveredAuth = true
        sendToFlutter(
            "onAuthToken",
            mapOf(
                "found" to false,
                "mode" to MODE_AUTH,
                "keys" to keys,
                "diag" to diag,
            )
        )
        finish()
    }

    private fun exitToReading() {
        sendToFlutter("exitToReading", null)
        finish()
    }

    /**
     * 链接模式下的非 http(s) 导航：等效真实浏览器。
     *
     * * `simple://...` 等自定义协议直接 ACTION_VIEW；
     * * `intent://...` 按 Chrome 的规则解析（URI_INTENT_SCHEME），并对
     *   解析结果做消毒：只接受 ACTION_VIEW、强制加 BROWSABLE 类别、
     *   清掉指定组件与 selector、重置 flags——不允许页面借 intent
     *   载荷拉起任意组件或带进奇怪的任务栈行为；
     * * 唤起成功后本页作为跳板直接收掉（返回键回到阅读界面）；
     * * 没有应用能接（官方 App 未安装等）时留在页面里，分享页自己的
     *   回落逻辑（3 秒后进官方下载页）照常工作。
     *
     * 返回 true 表示本次导航已处理，WebView 不要再加载它。
     */
    private fun launchExternal(uri: Uri): Boolean {
        val intent = try {
            if (uri.scheme?.lowercase() == "intent") {
                Intent.parseUri(uri.toString(), Intent.URI_INTENT_SCHEME)
            } else {
                Intent(Intent.ACTION_VIEW, uri)
            }
        } catch (e: Exception) {
            return true // 解析失败：留在容器内，不跳。
        }
        if (intent.action != Intent.ACTION_VIEW) return true
        return try {
            intent.addCategory(Intent.CATEGORY_BROWSABLE)
            intent.component = null
            intent.selector = null
            intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
            startActivity(intent)
            // 一键直达：跳转成功就收掉跳板。
            finish()
            true
        } catch (e: ActivityNotFoundException) {
            Toast.makeText(this, "没有应用能打开这个链接", Toast.LENGTH_SHORT).show()
            true
        } catch (e: Exception) {
            true
        }
    }

    /** 顶栏「系统浏览器」：把当前页面交给系统浏览器后收掉本页。 */
    private fun openInSystemBrowser() {
        val url = webView?.url ?: return
        if (url.isBlank()) return
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            finish()
        } catch (e: Exception) {
            Toast.makeText(this, "没有可用的浏览器应用", Toast.LENGTH_SHORT).show()
        }
    }

    /**
     * 经 MainActivity 缓存的 messenger 向 Dart 反向回传。
     * 引擎已销毁（极端时序）时静默放弃，不影响本页行为。
     */
    private fun sendToFlutter(method: String, arguments: Any?) {
        val messenger = cachedMessenger ?: return
        try {
            MethodChannel(messenger, CHANNEL)
                .invokeMethod(method, arguments, object : MethodChannel.Result {
                    override fun success(result: Any?) {}
                    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
                    override fun notImplemented() {}
                })
        } catch (e: Exception) {
            // 引擎可能在销毁中：静默。
        }
    }

    // ------------------------------------------------------------ 生命周期

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            onBackPressedInternal()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onDestroy() {
        finished = true
        handler.removeCallbacksAndMessages(null)
        webView?.apply {
            stopLoading()
            loadUrl("about:blank")
            destroyDrawingCache()
            destroy()
        }
        webView = null
        super.onDestroy()
    }
}
