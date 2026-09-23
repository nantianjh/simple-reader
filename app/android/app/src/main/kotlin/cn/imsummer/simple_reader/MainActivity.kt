package cn.imsummer.simple_reader

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 宿主引擎的 messenger 引用：BrowserActivity 拿到凭证后经它反向回传 Dart。
 * MainActivity 是根 Activity，WebView 页存活期间它必然存活；
 * onDestroy 时置空，避免悬挂引用。
 */
@Volatile
var cachedMessenger: BinaryMessenger? = null

/**
 * 宿主 Activity。
 *
 * 工程约定「运行时零第三方依赖」，因此所有需要系统能力的操作都通过
 * 自建的极简平台通道落到原生实现：
 *
 * 1. store  —— 键值存储，落在 SharedPreferences
 *      get    { key }                -> String?
 *      set    { key, value }         -> null
 *      remove { key }                -> null
 *
 * 2. files  —— 内容缓存文件，落在应用私有 filesDir/content_cache
 *      read   { name }               -> String?
 *      write  { name, content }      -> Boolean
 *      delete { name }               -> null
 *      list   {}                     -> List<String>
 *      stats  {}                     -> { count, bytes }
 *      purge  { maxAgeDays }         -> Int（删除的文件数）
 *
 * 3. logs   —— 运行日志文件，落在应用私有 filesDir/logs/run.log
 *      append { text }               -> Boolean
 *      read   {}                     -> String?
 *      clear  {}                     -> null
 *      size   {}                     -> Int（字节）
 *
 *    单独一条通道、单独一个目录：日志与内容缓存的生命周期不同，
 *    「清空内容缓存」「按保留期清理」都不应该把诊断日志一起删掉。
 *
 * 4. system —— 系统动作
 *      openUrl { url }               -> Boolean（是否成功唤起）
 *      exportBackup { fileName, content } -> String?（给用户看的位置描述；
 *                                      Android 10+ 经 MediaStore 落公共
 *                                      Download/Simple阅读，无需存储权限；
 *                                      更早版本回落应用外部私有目录
 *                                      files/backups/ 并返回绝对路径）
 *      importBackup {}               -> { name, content }?（弹系统文件选择器
 *                                      读取备份文本；用户取消返回 null）
 *      saveImage { bytes, fileName, mime } -> String（保存位置描述；
 *                                      Android 10+ 经 MediaStore 插入
 *                                      Pictures/Simple阅读，无需存储权限；
 *                                      更早版本回落应用外部私有目录）
 *
 * 5. browser —— 应用内浏览器容器（系统 WebView，见 BrowserActivity）
 *      open   { url }                -> Boolean（打开网页版，静默同步凭证）
 *      openLink { url, title }       -> Boolean（链接模式：非 http(s) 导航
 *                                       转交系统唤起对应应用，等效真实
 *                                       浏览器；唤起成功后自动收掉）
 *      login  {}                     -> Boolean（打开登录流程，取到 token 后
 *                                       原生以 onAuthToken 反向回传）
 *      peek   {}                     -> Boolean（离屏静默检测网页端登录态：
 *                                       不打开可见页面，后台加载官方首页后
 *                                       读取 localStorage，结果仍以
 *                                       onAuthToken 回传，mode="peek"）
 *      clearWebData {}              -> true（清除 WebView 的 Cookie 与 DOM 存储）
 *
 * 反向通道：BrowserActivity 拿到凭证 / 「切换到阅读模式」时，会通过
 * FlutterEngineCache 里的宿主引擎向同一通道发 onAuthToken / exitToReading，
 * Dart 侧在 NativeBridge.setBrowserHandlers 中接收。
 *
 * 存储文件位于 /data/data/cn.imsummer.simple_reader/ 下，属应用私有目录，
 * 未 root 的设备上其它应用无法读取。
 * **例外**：用户主动要拿走的东西一律落公共目录 —— 保存的图片进
 * `Pictures/Simple阅读`、导出的备份进 `Download/Simple阅读`（均走 MediaStore，
 * Android 10+ 无需存储权限，文件管理器直接可见）。
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL_STORE = "cn.imsummer.simple_reader/store"
        const val CHANNEL_FILES = "cn.imsummer.simple_reader/files"
        const val CHANNEL_LOGS = "cn.imsummer.simple_reader/logs"
        const val CHANNEL_SYSTEM = "cn.imsummer.simple_reader/system"
        const val CHANNEL_BROWSER = "cn.imsummer.simple_reader/browser"
        const val PREFS_NAME = "simple_reader_prefs"
        const val CACHE_DIR_NAME = "content_cache"
        const val LOG_DIR_NAME = "logs"
        const val LOG_FILE_NAME = "run.log"

        /** 数据备份目录：老系统（Android 9-）回落到外部私有目录时用。 */
        const val BACKUP_DIR_NAME = "backups"

        /** 公共目录下的应用子目录名（相册与「下载」共用同一层级名）。 */
        const val PUBLIC_DIR_NAME = "Simple阅读"

        /** 「导入备份」的文件选择请求码。 */
        const val REQUEST_IMPORT_BACKUP = 0x5A01

        /** 日志文件上限：超过后丢掉最旧的三分之一，保留最近记录。 */
        const val LOG_MAX_BYTES = 512 * 1024L
    }

    private val prefs: SharedPreferences
        get() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /**
     * 内容缓存目录。
     *
     * 命名刻意避开 `cacheDir`：Context 已有 `getCacheDir()`，
     * 同名属性会与之构成 JVM 签名冲突（Accidental override）。
     */
    private val contentCacheDir: File
        get() = File(filesDir, CACHE_DIR_NAME).also { if (!it.exists()) it.mkdirs() }

    /** 运行日志目录。 */
    private val logDir: File
        get() = File(filesDir, LOG_DIR_NAME).also { if (!it.exists()) it.mkdirs() }

    private val logFile: File
        get() = File(logDir, LOG_FILE_NAME)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_STORE)
            .setMethodCallHandler { call, result -> handleStore(call, result) }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_FILES)
            .setMethodCallHandler { call, result -> handleFiles(call, result) }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_LOGS)
            .setMethodCallHandler { call, result -> handleLogs(call, result) }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_SYSTEM)
            .setMethodCallHandler { call, result -> handleSystem(call, result) }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_BROWSER)
            .setMethodCallHandler { call, result -> handleBrowser(call, result) }

        // 引擎 messenger 存入顶层引用：BrowserActivity 拿到凭证后需要经它
        // 反向回传 Dart。
        cachedMessenger = flutterEngine.dartExecutor.binaryMessenger
    }

    override fun onDestroy() {
        // 先摘掉引用再让 super 销毁引擎，避免残留失效引用。
        cachedMessenger = null
        super.onDestroy()
    }

    // ------------------------------------------------------------- 键值存储

    private fun handleStore(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "get" -> {
                    val key = call.argument<String>("key")
                    if (key == null) {
                        result.error("bad_args", "缺少 key", null)
                    } else {
                        result.success(prefs.getString(key, null))
                    }
                }

                "set" -> {
                    val key = call.argument<String>("key")
                    val value = call.argument<String>("value")
                    if (key == null || value == null) {
                        result.error("bad_args", "缺少 key 或 value", null)
                    } else {
                        // apply() 异步落盘，不阻塞主线程。
                        prefs.edit().putString(key, value).apply()
                        result.success(null)
                    }
                }

                "remove" -> {
                    val key = call.argument<String>("key")
                    if (key == null) {
                        result.error("bad_args", "缺少 key", null)
                    } else {
                        prefs.edit().remove(key).apply()
                        result.success(null)
                    }
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // 凭证读写失败不应该让应用崩溃。
            result.error("prefs_error", e.message, null)
        }
    }

    // ------------------------------------------------------------- 缓存文件

    /**
     * 只接受纯文件名：拒绝路径分隔符与 .. ，
     * 避免越权写到私有目录之外。
     */
    private fun safeName(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        if (raw.contains('/') || raw.contains('\\') || raw.contains("..")) return null
        return raw
    }

    private fun handleFiles(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "read" -> {
                    val name = safeName(call.argument<String>("name"))
                    if (name == null) {
                        result.error("bad_args", "文件名不合法", null)
                    } else {
                        val f = File(contentCacheDir, name)
                        result.success(if (f.isFile) f.readText() else null)
                    }
                }

                "write" -> {
                    val name = safeName(call.argument<String>("name"))
                    val content = call.argument<String>("content")
                    if (name == null || content == null) {
                        result.error("bad_args", "文件名或内容缺失", null)
                    } else {
                        File(contentCacheDir, name).writeText(content)
                        result.success(true)
                    }
                }

                "delete" -> {
                    val name = safeName(call.argument<String>("name"))
                    if (name == null) {
                        result.error("bad_args", "文件名不合法", null)
                    } else {
                        File(contentCacheDir, name).delete()
                        result.success(null)
                    }
                }

                "list" -> {
                    val names = contentCacheDir.listFiles()
                        ?.filter { it.isFile }
                        ?.map { it.name }
                        ?: emptyList()
                    result.success(names)
                }

                "stats" -> {
                    val files = contentCacheDir.listFiles()?.filter { it.isFile } ?: emptyList()
                    var bytes = 0L
                    for (f in files) bytes += f.length()
                    result.success(mapOf("count" to files.size, "bytes" to bytes))
                }

                "purge" -> {
                    // maxAgeDays <= 0 视为「保留期内不过期」，直接返回 0。
                    val maxAgeDays = call.argument<Int>("maxAgeDays") ?: 0
                    if (maxAgeDays <= 0) {
                        result.success(0)
                    } else {
                        val limit = System.currentTimeMillis() -
                            maxAgeDays.toLong() * 24L * 60L * 60L * 1000L
                        var removed = 0
                        contentCacheDir.listFiles()?.forEach { f ->
                            if (f.isFile && f.lastModified() < limit) {
                                if (f.delete()) removed++
                            }
                        }
                        result.success(removed)
                    }
                }

                "clear" -> {
                    var removed = 0
                    contentCacheDir.listFiles()?.forEach { f ->
                        if (f.isFile && f.delete()) removed++
                    }
                    result.success(removed)
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // 缓存读写失败不应该让应用崩溃，最坏退化为「本次不使用缓存」。
            result.error("file_error", e.message, null)
        }
    }

    // ------------------------------------------------------------- 运行日志

    private fun handleLogs(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "append" -> {
                    val text = call.argument<String>("text")
                    if (text.isNullOrEmpty()) {
                        result.success(false)
                    } else {
                        val f = logFile
                        f.appendText(text)
                        // 超限时丢掉最旧的三分之一，保留最近记录。
                        if (f.length() > LOG_MAX_BYTES) {
                            val lines = f.readLines()
                            val keep = lines.drop(lines.size / 3)
                            f.writeText(keep.joinToString("\n", postfix = "\n"))
                        }
                        result.success(true)
                    }
                }

                "read" -> {
                    val f = logFile
                    result.success(if (f.isFile) f.readText() else null)
                }

                "clear" -> {
                    if (logFile.isFile) logFile.delete()
                    result.success(null)
                }

                "size" -> {
                    result.success(
                        if (logFile.isFile) logFile.length().toInt() else 0
                    )
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // 日志写入失败绝不能让应用崩溃。
            result.error("log_error", e.message, null)
        }
    }

    // ------------------------------------------------------------- 系统动作

    private fun handleSystem(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "openUrl" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("bad_args", "缺少 url", null)
                    } else {
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        try {
                            startActivity(intent)
                            result.success(true)
                        } catch (e: ActivityNotFoundException) {
                            result.success(false)
                        }
                    }
                }

                "exportBackup" -> {
                    val fileName = safeName(call.argument<String>("fileName"))
                    val content = call.argument<String>("content")
                    if (fileName == null || content == null) {
                        result.error("bad_args", "文件名或内容缺失", null)
                    } else {
                        // 写公共「下载」目录同样是几 MB 量级的 IO（备份可能带
                        // 全部缓存），放后台线程执行，避免卡住平台线程；
                        // 结果切回主线程回传（Result 约束）。
                        Thread {
                            try {
                                val location = saveBackupToDownloads(fileName, content)
                                Handler(Looper.getMainLooper()).post {
                                    result.success(location)
                                }
                            } catch (e: Exception) {
                                Handler(Looper.getMainLooper()).post {
                                    result.error(
                                        "export_failed",
                                        e.message ?: "导出失败",
                                        null
                                    )
                                }
                            }
                        }.start()
                    }
                }

                "importBackup" -> {
                    if (pendingImport != null) {
                        result.error("busy", "已有一次导入在进行", null)
                    } else {
                        // ACTION_OPEN_DOCUMENT：不需要任何存储权限，
                        // 用户选完即拿到该文件的一次性读取授权。
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/json"
                            putExtra(
                                Intent.EXTRA_MIME_TYPES,
                                arrayOf(
                                    "application/json",
                                    "text/plain",
                                    "application/octet-stream",
                                ),
                            )
                        }
                        try {
                            pendingImport = result
                            startActivityForResult(intent, REQUEST_IMPORT_BACKUP)
                        } catch (e: Exception) {
                            pendingImport = null
                            result.error("no_picker", e.message, null)
                        }
                    }
                }

                "saveImage" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val fileName = safeName(call.argument<String>("fileName"))
                    val mime = call.argument<String>("mime") ?: "image/jpeg"
                    if (bytes == null || bytes.isEmpty() || fileName == null) {
                        result.error("bad_args", "缺少图片数据或文件名", null)
                    } else {
                        // 相册写入涉及几 MB 的 IO，放到后台线程执行，避免
                        // 卡住平台线程；结果切回主线程回传（Result 约束）。
                        Thread {
                            try {
                                val location = saveToGallery(bytes, fileName, mime)
                                Handler(Looper.getMainLooper()).post {
                                    result.success(location)
                                }
                            } catch (e: Exception) {
                                Handler(Looper.getMainLooper()).post {
                                    result.error("save_failed", e.message ?: "保存失败", null)
                                }
                            }
                        }.start()
                    }
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("system_error", e.message, null)
        }
    }

    // ------------------------------------------------------------- 图片落相册

    /**
     * 把图片字节写入系统相册，返回给用户看的位置描述。
     *
     * Android 10+：MediaStore 插入 Pictures/Simple阅读，无需存储权限，
     * 相册应用立即可见；同名文件由系统自动加后缀去重。IS_PENDING 置位
     * 到写完再清除，避免相册扫到半截文件。
     * Android 9-：没有免权限写公共目录的途径（运行时权限方案对本应用
     * 的使用频率不划算），回落到应用外部私有目录 files/Pictures/ ——
     * 无需权限，文件管理器可以取到，只是相册应用不索引。
     * 在后台线程调用（见 handleSystem 的 saveImage 分支）。
     */
    private fun saveToGallery(bytes: ByteArray, fileName: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                put(MediaStore.Images.Media.MIME_TYPE, mime)
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    Environment.DIRECTORY_PICTURES + "/" + PUBLIC_DIR_NAME
                )
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("系统拒绝了相册写入请求")
            try {
                contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                    ?: throw IllegalStateException("无法写入相册文件")
            } catch (e: Exception) {
                // 写一半失败：把残留的空记录清掉，避免相册出现 0 字节坏项。
                runCatching { contentResolver.delete(uri, null, null) }
                throw e
            }
            val done = ContentValues().apply {
                put(MediaStore.Images.Media.IS_PENDING, 0)
            }
            contentResolver.update(uri, done, null, null)
            return "相册/$PUBLIC_DIR_NAME/$fileName"
        }
        val dir = File(getExternalFilesDir(Environment.DIRECTORY_PICTURES), PUBLIC_DIR_NAME)
            .also { if (!it.exists()) it.mkdirs() }
        val f = File(dir, fileName)
        f.writeBytes(bytes)
        return f.absolutePath
    }

    // --------------------------------------------------- 备份落公共目录

    /**
     * 把备份文本写进**用户可见的公共目录**，返回给用户看的位置描述。
     *
     * 需求（2026-09-22）：导出目录不能落在 data 私有目录 —— 此前写的是
     * `getExternalFilesDir(null)/backups`（即
     * `/storage/emulated/0/Android/data/<包名>/files/backups`），属**应用外部
     * 私有目录**：用户用系统「文件」或第三方文件管理器翻不到，只能 adb pull，
     * 对"换机迁移"这个主要用途等于不可用。
     *
     * Android 10+：MediaStore 插入 `Download/Simple阅读/`，无需存储权限，
     * 系统「文件」应用与第三方文件管理器立即可见，也能直接用数据线拷走；
     * 同名文件由系统自动加后缀去重。IS_PENDING 置位到写完再清除，避免
     * 文件管理器扫到半截文件（与 [saveToGallery] 同一套路）。
     * Android 9-：没有免权限写公共目录的途径，回落到原外部私有目录
     * `files/backups/`（无需权限，文件管理器与 adb 可取），返回真实绝对路径
     * 让用户知道去哪儿拿。
     *
     * 在后台线程调用（见 handleSystem 的 exportBackup 分支）。
     */
    private fun saveBackupToDownloads(fileName: String, content: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                put(MediaStore.Downloads.MIME_TYPE, "application/json")
                put(
                    MediaStore.Downloads.RELATIVE_PATH,
                    Environment.DIRECTORY_DOWNLOADS + "/" + PUBLIC_DIR_NAME
                )
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = contentResolver.insert(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
            ) ?: throw IllegalStateException("系统拒绝了下载目录写入请求")
            try {
                contentResolver.openOutputStream(uri)?.use {
                    it.write(content.toByteArray(Charsets.UTF_8))
                } ?: throw IllegalStateException("无法写入备份文件")
            } catch (e: Exception) {
                // 写一半失败：清掉残留记录，避免下载目录出现 0 字节坏项。
                runCatching { contentResolver.delete(uri, null, null) }
                throw e
            }
            val done = ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }
            contentResolver.update(uri, done, null, null)
            return "下载/$PUBLIC_DIR_NAME/$fileName"
        }
        val dir = File(getExternalFilesDir(null), BACKUP_DIR_NAME)
            .also { if (!it.exists()) it.mkdirs() }
        val f = File(dir, fileName)
        f.writeText(content, Charsets.UTF_8)
        return f.absolutePath
    }

    // ------------------------------------------------------------- 数据备份

    /** 等待系统文件选择结果的通道回调（同一时刻只允许一次）。 */
    private var pendingImport: MethodChannel.Result? = null

    /**
     * 文件选择（导入备份）的回调。
     *
     * 只处理本页发起的 [REQUEST_IMPORT_BACKUP]，其余请求码交给 super
     * —— FlutterActivity 还需要把结果转发给插件（本项目不引入插件，
     * 但保持转发不会有害）。
     */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_IMPORT_BACKUP) return
        val pending = pendingImport ?: return
        pendingImport = null

        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            pending.success(null) // 用户取消：由 Dart 侧静默处理
            return
        }
        try {
            val text = contentResolver.openInputStream(uri)?.use { input ->
                input.readBytes().toString(Charsets.UTF_8)
            } ?: ""
            pending.success(
                mapOf(
                    "name" to (uri.lastPathSegment ?: ""),
                    "content" to text,
                )
            )
        } catch (e: Exception) {
            pending.error("read_failed", e.message, null)
        }
    }

    // ------------------------------------------------------------- 应用内浏览器

    private fun handleBrowser(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "open" -> {
                    // url 可缺省：网页版入口不带 URL，由 BrowserActivity
                    // 内部回落到官方 Web 端首页。
                    val url = call.argument<String>("url")?.takeIf { it.isNotBlank() }
                    result.success(startBrowser(BrowserActivity.MODE_WEB, url, "官方网页版"))
                }

                "openLink" -> {
                    // 链接模式：容器内打开 http(s) 页面，页面里的非 http(s)
                    // 导航（simple:// 深链、intent:// 等）转交系统唤起对应
                    // 应用——"在 Simple 中打开"分享页就靠它一键跳进官方 App。
                    // url 必填；title 选填（顶栏标题，缺省给中性标题）。
                    val url = call.argument<String>("url")?.takeIf { it.isNotBlank() }
                    if (url == null) {
                        result.error("bad_args", "缺少 url", null)
                    } else {
                        val title = call.argument<String>("title")
                            ?.takeIf { it.isNotBlank() } ?: "外部链接"
                        result.success(startBrowser(BrowserActivity.MODE_LINK, url, title))
                    }
                }

                "login" -> {
                    result.success(startBrowser(BrowserActivity.MODE_AUTH, null, "账号登录"))
                }

                "peek" -> {
                    result.success(startPeek())
                }

                "clearWebData" -> {
                    // 退出登录时联动清除 WebView 的 Cookie 与 DOM 存储，
                    // 否则下次打开网页版仍是旧的登录态。
                    CookieManager.getInstance().apply {
                        removeAllCookies(null)
                        flush()
                    }
                    WebStorage.getInstance().deleteAllData()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("browser_error", e.message, null)
        }
    }

    /** 启动浏览器容器。返回是否成功拉起（WebView 初始化失败等极端情况返回 false）。 */
    private fun startBrowser(mode: String, url: String?, title: String): Boolean {
        return try {
            val intent = Intent(this, BrowserActivity::class.java)
                .putExtra(BrowserActivity.EXTRA_MODE, mode)
                .putExtra(BrowserActivity.EXTRA_TITLE, title)
            if (url != null) intent.putExtra(BrowserActivity.EXTRA_URL, url)
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    // ------------------------------------------------- 离屏登录态检测（peek）

    /**
     * 不打开任何可见页面，在后台静默检测官方 Web 端是否已有登录态。
     *
     * 做法：创建 1x1 像素并移出屏幕外的离屏 WebView（仍正常渲染执行 JS），
     * 加载官方首页后用 [WebAuthProbe] 读取 localStorage 里的凭证，
     * 结果经 onAuthToken（mode="peek"）回传 Dart，随即销毁 WebView。
     * 用途：凭证配置页进入时「检测到网页端已登录则自动接管」——用户
     * 之前在应用内登录过但凭证没同步成功时，下次进凭证页即自动补救。
     */
    private var peekWebView: WebView? = null
    private val peekHandler = Handler(Looper.getMainLooper())
    private var peekReadTries = 0

    /** 离屏检测的读取重试次数（页面加载后最多再读 2 次，覆盖 SPA 晚写盘）。 */
    private fun startPeek(): Boolean {
        if (peekWebView != null) return false // 已有检测在进行
        return try {
            val wv = WebView(this).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                // 与 BrowserActivity 一致：去掉 WebView 专属标记。
                settings.userAgentString =
                    settings.userAgentString.replace("; wv", "", ignoreCase = true)
                webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView, url: String) {
                        // SPA 启动后可能还要写一次存储，稍作延迟再读；
                        // 读不到还有 [readPeek] 的重试与超时兜底。
                        peekHandler.postDelayed({ readPeek() }, 800L)
                    }
                }
            }
            // 1x1 像素且平移出屏幕：不产生可见 UI，也不遮挡 Flutter 界面。
            wv.translationX = -2000f
            addContentView(
                wv,
                FrameLayout.LayoutParams(1, 1)
            )
            peekWebView = wv
            peekReadTries = 0
            wv.loadUrl(WebAuthProbe.WEB_HOME)
            // 兜底超时：无论卡在加载还是读取，15 秒后按未登录收场。
            peekHandler.postDelayed({ sendPeek(WebAuthProbe.Result.miss()) }, 15000L)
            true
        } catch (e: Throwable) {
            false
        }
    }

    private fun readPeek() {
        val wv = peekWebView ?: return
        wv.evaluateJavascript(WebAuthProbe.JS) { raw ->
            val res = WebAuthProbe.parse(raw)
            if (res.found) {
                sendPeek(res)
            } else if (peekReadTries < 2) {
                peekReadTries++
                peekHandler.postDelayed({ readPeek() }, 2500L)
            } else {
                sendPeek(res)
            }
        }
    }

    /** 回传检测结果并销毁离屏 WebView。 */
    private fun sendPeek(res: WebAuthProbe.Result) {
        val messenger = cachedMessenger
        finishPeek()
        if (messenger == null) return
        try {
            MethodChannel(messenger, CHANNEL_BROWSER)
                .invokeMethod(
                    "onAuthToken",
                    mapOf(
                        "found" to res.found,
                        "token" to res.token,
                        "authToken" to res.authToken,
                        "mode" to "peek",
                        "keys" to res.keys,
                        "diag" to res.diag,
                    ),
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {}
                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
                        override fun notImplemented() {}
                    }
                )
        } catch (e: Exception) {
            // 引擎可能在销毁中：静默。
        }
    }

    private fun finishPeek() {
        peekHandler.removeCallbacksAndMessages(null)
        peekWebView?.let { wv ->
            (wv.parent as? ViewGroup)?.removeView(wv)
            wv.stopLoading()
            wv.destroy()
        }
        peekWebView = null
        peekReadTries = 0
    }
}
