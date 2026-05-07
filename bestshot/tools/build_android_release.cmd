@echo off
setlocal

set "JAVA_HOME=C:\Progra~1\ECLIPS~1\JDK-17~1.8-H"
set "ANDROID_SDK_ROOT=C:\Android\Sdk"
set "ANDROID_HOME=C:\Android\Sdk"

REM Pick the installed NDK folder (the one Flutter just installed).
set "ANDROID_NDK_HOME=%ANDROID_SDK_ROOT%\ndk\28.2.13676358"
set "CMAKE_BIN=%ANDROID_SDK_ROOT%\cmake\3.22.1\bin"

set "PATH=%JAVA_HOME%\bin;%ANDROID_NDK_HOME%;%ANDROID_SDK_ROOT%\platform-tools;%ANDROID_SDK_ROOT%\cmdline-tools\latest\bin;%CMAKE_BIN%;%PATH%"

echo JAVA_HOME=%JAVA_HOME%
echo ANDROID_SDK_ROOT=%ANDROID_SDK_ROOT%
echo ANDROID_NDK_HOME=%ANDROID_NDK_HOME%

cd /d "%~dp0.."
flutter build apk --release -v
exit /b %ERRORLEVEL%

