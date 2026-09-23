@echo off
rem 单 ABI 构建脚本：只在 arm64 真机自用，产物约 17MB
rem （默认的 flutter build apk 是三平台 fat APK，约 50MB）。
rem
rem 说明：自 v1.8.6 起，android/settings.gradle.kts 已把 release 固定为
rem arm64（注入项目级 extra 属性 target-platform，压过 flutter CLI 的 -P），
rem 因此下面这个 --target-platform 参数只是显式兜底，去掉也一样只出 arm64。
rem APK 构建完成后会由 gradle 任务 archiveReleaseApkToDist 自动复制一份到
rem 仓库根 dist\Simple阅读-v<版本>-release.apk（同名覆盖）。
rem 用法：双击，或在本目录命令行运行。
cd /d "%~dp0"
flutter build apk --release --target-platform android-arm64
echo.
echo 产物：build\app\outputs\flutter-apk\app-release.apk
echo 归档：..\dist\Simple阅读-v^<版本^>-release.apk
pause
