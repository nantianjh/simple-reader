import com.android.build.api.artifact.SingleArtifact
import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ─────────────────────────────────────────────────────────────────────────────
// 过渡构建开关：把 applicationId 临时切回更名前的 cn.imsummer.simple_search。
//
// 只有一个用途：v1.9.0 更名（simple_search → simple_reader）后，旧包名留在
// 设备上的本机数据在新包名下读不到（两个包名＝两个应用）。装一个同旧包名的
// 过渡包（系统按「同包名 + 同签名」覆盖安装，数据完整保留），就能用应用内的
// 「高级设置 → 数据备份 → 导出数据」把旧数据取出来，再装新包名版本导入。
//
// 打开方式：在 `android/gradle.properties` 临时加一行
//     simple.legacyAppId=true
// 构建完记得删掉。namespace 不变（始终 simple_reader），所以清单里的相对
// Activity 名、MethodChannel 名、SharedPreferences 名都不受影响，只是
// 安装标识与数据目录换回旧包名。
// ─────────────────────────────────────────────────────────────────────────────
val legacyAppId = (project.findProperty("simple.legacyAppId") as String?) == "true"

// ─────────────────────────────────────────────────────────────────────────────
// 发布签名（永久密钥）
//
// 背景：v1.9.4 及以前 release 直接复用 AGP 的 **debug 签名配置**
// （`signingConfig = signingConfigs.getByName("debug")`），它读
// `$HOME/.android/debug.keystore`。debug 密钥在语义上是**一次性**的：
// Android Studio 删掉它会自动重新生成一把，届时 release 产物的签名身份会
// 静默改变，已装机的应用再也无法覆盖升级（INSTALL_FAILED_UPDATE_
// INCOMPATIBLE），而卸载重装会清空 token / 缓存 / 设置 / 已读线。
//
// 现在把本机那把密钥（证书 SHA-256 25:F9:A6:…:B0:25，有效期至 2055-10-12）
// 复制成**独立、显式、可长期依赖**的发布密钥库，由 `android/key.properties`
// 引用，不再与 debug 工具链的生命周期耦合：
//   <仓库根>/.workbuddy/keys/simple-reader-release.jks   （密钥库本体）
//   app/android/key.properties                           （路径与口令，本机文件）
// 两者均已 gitignore——公开仓库绝不入库。云端由
// .github/workflows/android-build.yml 从 Secret 还原成同样的配置。
//
// 密钥材料与旧 debug 密钥**完全相同**，所以签名指纹不变，老设备仍能原地
// 升级，不存在迁移成本。
//
// 回退：key.properties 缺失或其中 storeFile 指向的文件不存在时，退回 debug
// 签名配置——保证任何机器 clone 下来都能直接 `flutter build apk --release`
// （CI 校验、第三方自构建），代价只是产物无法覆盖安装到已有设备。
// ─────────────────────────────────────────────────────────────────────────────
val keystorePropsFile: File = rootProject.file("key.properties")
// ⚠️ 必须用 `import java.util.Properties` 后的短名：Kotlin DSL 里 `java` 会被解析成
//    Project 的 java 扩展，写 `java.util.Properties()` 会编译失败（Unresolved reference 'util'）。
val keystoreProps: Properties = Properties()
if (keystorePropsFile.isFile) {
    keystorePropsFile.inputStream().use { stream -> keystoreProps.load(stream) }
}
val releaseStoreFile: File? = keystoreProps.getProperty("storeFile")?.let { path -> File(path) }
val hasReleaseKeystore: Boolean = releaseStoreFile?.isFile == true

android {
    namespace = "cn.imsummer.simple_reader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 正式标识 = cn.imsummer.simple_reader；过渡构建（见文件头说明）临时
        // 用回旧包名，以便覆盖安装旧版本并读出它的本机数据。
        applicationId =
            if (legacyAppId) "cn.imsummer.simple_search" else "cn.imsummer.simple_reader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 单 ABI 说明：Flutter 插件会按构建参数向 defaultConfig 注入三平台
    // ndk.abiFilters（fat APK ~50MB）；在 gradle 里改 abiFilters 或 splits
    // 都会与插件注入冲突（实测）。release 的 arm64 固定已上移到
    // `android/settings.gradle.kts`（beforeProject 注入项目级 extra 属性
    // target-platform，优先级高于 CLI 的 -P）。手工构建时仍可显式指定：
    //   flutter build apk --release --target-platform android-arm64
    // （见 app/build_arm64.cmd），产物 ~17MB。

    // 永久发布密钥（见文件头「发布签名（永久密钥）」）。仅当 key.properties
    // 存在且密钥库文件可访问时才注册，否则下方 release 回退到 debug 签名。
    signingConfigs {
        // 先取到局部 val，Kotlin 才能对可空类型做智能转换（直接读外层的
        // File? 变量在 lambda 里不会被转换，会报 "Only safe calls allowed"）。
        val releaseKeyFile = releaseStoreFile
        if (hasReleaseKeystore && releaseKeyFile != null) {
            create("release") {
                storeFile = releaseKeyFile
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 永久密钥优先；缺失时退回 debug 签名（见文件头说明）。
            // 不再写死 debug：写死会让「哪把密钥签的」隐式依赖本机
            // ~/.android 的状态，正是本次要根治的问题。
            signingConfig =
                if (hasReleaseKeystore) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
        }
    }
}

// 让「这一轮到底用哪把密钥签的」在构建日志里一眼可见（每台机器打印一次）。
logger.lifecycle(
    if (hasReleaseKeystore) {
        "[签名] release 使用永久发布密钥：${releaseStoreFile?.path}"
    } else {
        "[签名] ⚠️ 未找到 app/android/key.properties（或密钥库文件缺失），" +
            "release 退回 debug 签名——产物无法覆盖安装到已有设备。"
    },
)

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// ─────────────────────────────────────────────────────────────────────────────
// 构建产物自动归档到仓库根的 dist/
//
// 每次 release 构建把 APK 复制一份到 <仓库根>/dist/Simple阅读-v<版本>-release.apk
// （同名覆盖，命名沿用 dist/ 里的历史约定）。两条入口都覆盖：
//   flutter build apk --release        →  :app:assembleRelease
//   cd app/android && gradlew assembleRelease
//
// 依赖顺序：package<Release> → archive<Release>ApkToDist → assemble<Release>，
// 因此打包失败时不会把上一轮的旧 APK 复制进 dist。
// 版本号取 flutter.versionName（= pubspec 的 version 名；flutter CLI 每次构建前
// 会把它写进 android/local.properties），保证文件名与 APK 内记录的版本一致。
// ─────────────────────────────────────────────────────────────────────────────
val repoRootDir: File = rootProject.projectDir.parentFile.parentFile
// 过渡构建（旧包名）不落 dist：它不该被当成正式产物。临时包放 analysis/，
// 该目录不入库。
val distDir: File =
    if (legacyAppId) File(repoRootDir, "analysis/legacy-apk") else File(repoRootDir, "dist")
val apkNamePrefix = if (legacyAppId) "Simple搜索-过渡包" else "Simple阅读"

androidComponents {
    onVariants { variant ->
        if (variant.buildType != "release") return@onVariants
        val capName = variant.name.replaceFirstChar { it.uppercaseChar() }
        val archiveTask =
            tasks.register<Copy>("archive${capName}ApkToDist") {
                group = "flutter"
                description = "把 ${variant.name} 的 APK 复制到 dist/（版本号命名，同名覆盖）"
                // AGP 的 APK 产物目录（单 APK 构建时目录内只有一个 *.apk）
                from(variant.artifacts.get(SingleArtifact.APK)) { include("*.apk") }
                into(distDir)
                rename { "$apkNamePrefix-v${flutter.versionName}-release.apk" }
            }
        archiveTask.configure {
            dependsOn(tasks.matching { it.name == "package$capName" })
        }
        tasks.matching { it.name == "assemble$capName" }.configureEach {
            dependsOn(archiveTask)
        }
    }
}
