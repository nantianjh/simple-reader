pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

include(":app")

// ─────────────────────────────────────────────────────────────────────────────
// 单 ABI 固定为 arm64（release）
//
// 为什么必须写在 settings 脚本里：
//   flutter CLI 构建 APK 时会传 `-Ptarget-platform=android-arm,android-arm64,android-x64`，
//   Flutter Gradle 插件在 **apply() 阶段**（即 app/build.gradle.kts 的 plugins {} 块，
//   早于脚本正文）就用 FlutterPluginUtils.getTargetPlatforms() 读走 target-platform，
//   之后无法再改；在 app 模块里写 ndk.abiFilters 也无效——插件会 clear() 后重新填
//   三平台（见 FlutterPlugin.configureAbiWithoutSplits）。
//
// 为什么用 beforeProject 注入项目级 extra 属性：
//   settings 脚本先于所有项目脚本执行，而 extra 属性的查找优先级 **高于** 命令行 -P，
//   于是能在插件读取之前把值换成 arm64。
//   ⚠️ 不要改用 gradle.startParameter.setProjectProperties()：Gradle 9.3.1 实测
//   命令行 -P 仍然优先，改了没用（已用最小工程验证过一次，别再走这条死路）。
//
// 效果：release 只编译/打包 arm64-v8a（APK ≈17MB，原三平台 fat APK ≈50MB）。
//
// debug 不干预：flutter run 会按目标设备传 ABI（x86_64 模拟器 = android-x64），
// 强行改成 arm64 会让模拟器因缺 .so 起不来。
// ─────────────────────────────────────────────────────────────────────────────
val requestedTasks: List<String> = gradle.startParameter.taskNames
val debugOnlyRequest: Boolean =
    requestedTasks.isNotEmpty() &&
        requestedTasks.all { it.contains("debug", ignoreCase = true) }
if (!debugOnlyRequest) {
    gradle.beforeProject {
        extensions.extraProperties.set("target-platform", "android-arm64")
    }
}
