set -euo pipefail
export GOPATH="$HOME/go"
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
export PATH="/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$GOPATH/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools"

cd /mnt/b/1CODING/zeon-app/hiddify-core

go version
java -version

# Try target toolchain first; fallback to host toolchain if unavailable
if GOTOOLCHAIN=go1.25.6 go version >/tmp/go_toolchain_check.txt 2>/tmp/go_toolchain_check.err; then
  export GOTOOLCHAIN=go1.25.6
  echo "Using GOTOOLCHAIN=$GOTOOLCHAIN"
else
  echo "go1.25.6 toolchain unavailable, fallback to host toolchain" >&2
fi

export CGO_LDFLAGS='-O2 -g -s -w -Wl,-z,max-page-size=16384'

"$GOPATH/bin/gomobile" bind -v \
  -androidapi=21 \
  -javapkg=com.hiddify.core \
  -libname=hiddify-core \
  -tags=with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,with_grpc,with_awg,tfogo_checklinkname0,with_naive_outbound,with_conntrack \
  -trimpath \
  -ldflags='-w -s -checklinkname=0 -buildid=' \
  -target=android \
  -o bin/hiddify-core.aar \
  github.com/sagernet/sing-box/experimental/libbox ./platform/mobile

ls -lh bin/hiddify-core.aar
cp -f bin/hiddify-core.aar /mnt/b/1CODING/zeon-app/android/app/libs/hiddify-core.aar