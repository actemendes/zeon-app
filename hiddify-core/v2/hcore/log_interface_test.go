package hcore

import (
	"context"
	"io"
	"strings"
	"testing"
	"time"

	"github.com/sagernet/sing-box/log"
)

// Model StartedService's debug callback, with a bound so regressions fail
// without exhausting the process stack.
type debugCallbackWriter struct {
	calls int
}

func (w *debugCallbackWriter) WriteMessage(_ log.Level, message string) {
	w.calls++
	if w.calls > 4 {
		panic("native log callback recursively entered the source logger")
	}
	(&LogInterface{}).WriteDebugMessage(message)
}

func TestNativeLogCallbackDoesNotReenterSourceLogger(t *testing.T) {
	for _, message := range []string{"[SmartActiveLifecycle] start", "ordinary debug message"} {
		t.Run(message, func(t *testing.T) {
			previousLogger, previousLevel := log.StdLogger(), static.logLevel
			t.Cleanup(func() { log.SetStdLogger(previousLogger); static.logLevel = previousLevel })
			static.logLevel = LogLevel_DEBUG
			writer := &debugCallbackWriter{}
			factory := log.NewDefaultFactory(context.Background(), log.Formatter{}, io.Discard, "", writer, false)
			t.Cleanup(func() { _ = factory.Close() })
			log.SetStdLogger(factory.Logger())
			sub := static.logObserver.Subscribe(8)
			t.Cleanup(func() { static.logObserver.Unsubscribe(sub) })
			defer func() {
				if recovered := recover(); recovered != nil {
					t.Errorf("%v", recovered)
				}
			}()
			log.Info(message)
			if writer.calls != 1 {
				t.Fatalf("source callback count = %d, want 1", writer.calls)
			}
			select {
			case entry := <-sub:
				if !strings.Contains(entry.Message, message) {
					t.Fatalf("diagnostic message lost: %q", entry.Message)
				}
				want := LogLevel_DEBUG
				if isSmartActiveDiagnosticMessage(message) {
					want = LogLevel_WARNING
				}
				if entry.Level != want || entry.Type != LogType_SERVICE {
					t.Fatalf("incorrect forwarded diagnostic: %v", entry)
				}
			case <-time.After(time.Second):
				t.Fatal("native diagnostic did not reach the observer")
			}
		})
	}
}

func TestSmartActiveDiagnosticMessageDetection(t *testing.T) {
	for _, marker := range smartActiveDiagnosticMarkers {
		if !isSmartActiveDiagnosticMessage("prefix " + marker + " suffix") {
			t.Fatalf("marker %q was not detected", marker)
		}
	}
	if isSmartActiveDiagnosticMessage("[Unrelated] message") {
		t.Fatal("unrelated log message was detected as Smart Active diagnostic")
	}
}
