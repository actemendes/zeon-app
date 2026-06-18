package monitoring

import (
	"fmt"
	"os"
	"runtime"
	"strings"
)

func SafeDiagnosticLog(args ...any) {
	message := fmt.Sprint(args...)
	if !isSafeDiagnosticMessage(message) {
		return
	}
	_, _ = fmt.Fprintln(os.Stderr, message)
	if runtime.GOOS == "android" {
		appendAndroidDiagnosticLog(message)
	}
}

func isSafeDiagnosticMessage(message string) bool {
	return strings.Contains(message, "[AutoDecision]") ||
		strings.Contains(message, "[AutoDecisionCandidates]") ||
		strings.Contains(message, "[LiveProbe]") ||
		strings.Contains(message, "[LiveAvoid]") ||
		strings.Contains(message, "[RoundRobinCandidates]") ||
		strings.Contains(message, "[BalanceQuality]")
}

func appendAndroidDiagnosticLog(message string) {
	file, err := os.OpenFile("/storage/emulated/0/Android/data/com.zeon.hiddify/files/auto_diagnostics.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer file.Close()
	_, _ = fmt.Fprintln(file, message)
}
