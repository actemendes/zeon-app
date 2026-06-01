set -euo pipefail
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools"
sdkmanager --version
yes | sdkmanager --licenses >/tmp/sdk_licenses.log || true
sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0" "ndk;28.2.13676358"