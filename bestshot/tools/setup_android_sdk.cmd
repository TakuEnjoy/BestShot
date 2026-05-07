@echo off
setlocal

set "ANDROID_SDK_ROOT=C:\Android\Sdk"
set "JAVA_HOME=C:\Program Files\Eclipse Adoptium\jdk-17.0.18.8-hotspot"
set "PATH=%JAVA_HOME%\bin;%ANDROID_SDK_ROOT%\cmdline-tools\latest\bin;%ANDROID_SDK_ROOT%\platform-tools;%PATH%"

echo ANDROID_SDK_ROOT=%ANDROID_SDK_ROOT%
echo JAVA_HOME=%JAVA_HOME%

if not exist "%ANDROID_SDK_ROOT%\cmdline-tools\latest\bin\sdkmanager.bat" (
  echo ERROR: sdkmanager.bat not found. Ensure cmdline-tools installed at:
  echo   %ANDROID_SDK_ROOT%\cmdline-tools\latest
  exit /b 1
)

echo Installing SDK packages...
(for /l %%i in (1,1,200) do @echo y) | call "%ANDROID_SDK_ROOT%\cmdline-tools\latest\bin\sdkmanager.bat" --sdk_root="%ANDROID_SDK_ROOT%" --install ^
  "platform-tools" ^
  "cmdline-tools;latest" ^
  "build-tools;28.0.3" ^
  "platforms;android-36" ^
  "cmake;3.22.1" ^
  "platforms;android-35" ^
  "build-tools;35.0.0" ^
  "platforms;android-34" ^
  "build-tools;34.0.0"
if errorlevel 1 exit /b 1

echo Accepting licenses...
(for /l %%i in (1,1,200) do @echo y) | call "%ANDROID_SDK_ROOT%\cmdline-tools\latest\bin\sdkmanager.bat" --sdk_root="%ANDROID_SDK_ROOT%" --licenses
if errorlevel 1 exit /b 1

echo Done.
exit /b 0

