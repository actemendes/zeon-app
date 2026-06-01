set -euo pipefail
export PATH="/usr/local/go/bin:$PATH"
export GOPATH="$HOME/go"
export PATH="$PATH:$GOPATH/bin"
export ANDROID_HOME="$HOME/Android/Sdk"
export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools"

go version
java -version

go install -v github.com/sagernet/gomobile/cmd/gomobile@v0.1.11
go install -v github.com/sagernet/gomobile/cmd/gobind@v0.1.11
"$GOPATH/bin/gomobile" version
"$GOPATH/bin/gomobile" init -v