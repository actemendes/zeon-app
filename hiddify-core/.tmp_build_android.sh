set -euo pipefail
export PATH="/c/Users/ZEON/devtools/go/bin:/c/Users/ZEON/go/bin:$PATH"
export ANDROID_HOME="C:/Users/ZEON/devtools/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_NDK_HOME="C:/Users/ZEON/devtools/android-sdk/ndk/28.2.13676358"
export JAVA_HOME="C:/Users/ZEON/devtools/jdk/jdk-17.0.19+10"
cd /b/1CODING/zeon-app/hiddify-core
echo "SCRIPT_START_REAL"
CGO_LDFLAGS="-O2 -g -s -w -Wl,-z,max-page-size=16384" gomobile bind -v -androidapi=21 -javapkg=com.hiddify.core -libname=hiddify-core -tags=with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,tfogo_checklinkname0,with_naive_outbound,with_conntrack -trimpath -ldflags="-w -s -checklinkname=0 -buildid=" -target=android -o bin/hiddify-core.aar github.com/sagernet/sing-box/experimental/libbox ./platform/mobile
echo "SCRIPT_END_REAL"