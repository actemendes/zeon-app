//go:build zeon_route_validation

package daemon

import (
	"context"
	"testing"

	"github.com/sagernet/sing-box/log"
)

type validationLogTestHandler struct {
	debugMessages []string
	level         log.Level
	levelMessage  string
}

func (h *validationLogTestHandler) ServiceStop() error {
	return nil
}

func (h *validationLogTestHandler) ServiceReload() error {
	return nil
}

func (h *validationLogTestHandler) SystemProxyStatus() (*SystemProxyStatus, error) {
	return nil, nil
}

func (h *validationLogTestHandler) SetSystemProxyEnabled(bool) error {
	return nil
}

func (h *validationLogTestHandler) WriteDebugMessage(message string) {
	h.debugMessages = append(h.debugMessages, message)
}

func (h *validationLogTestHandler) WriteMessage(level log.Level, message string) {
	h.level = level
	h.levelMessage = message
}

func TestValidationLogIsForwardedWithOriginalLevelOutsideDebug(t *testing.T) {
	handler := new(validationLogTestHandler)
	service := NewStartedService(ServiceOptions{
		Context:     context.Background(),
		Handler:     handler,
		Debug:       false,
		LogMaxLines: 10,
	})

	const message = `ZEON_ROUTE_VALIDATION {"kind":"route"}`
	service.WriteMessage(log.LevelWarn, message)

	if handler.level != log.LevelWarn {
		t.Fatalf("forwarded level = %v, want %v", handler.level, log.LevelWarn)
	}
	if handler.levelMessage != message {
		t.Fatalf("forwarded message = %q, want %q", handler.levelMessage, message)
	}
	if len(handler.debugMessages) != 0 {
		t.Fatalf("unexpected debug forwarding: %q", handler.debugMessages)
	}
}

func TestOrdinaryLogIsNotForwardedOutsideDebug(t *testing.T) {
	handler := new(validationLogTestHandler)
	service := NewStartedService(ServiceOptions{
		Context:     context.Background(),
		Handler:     handler,
		Debug:       false,
		LogMaxLines: 10,
	})

	service.WriteMessage(log.LevelWarn, "ordinary warning")

	if handler.levelMessage != "" {
		t.Fatalf("ordinary message was promoted: %q", handler.levelMessage)
	}
	if len(handler.debugMessages) != 0 {
		t.Fatalf("unexpected debug forwarding: %q", handler.debugMessages)
	}
}
