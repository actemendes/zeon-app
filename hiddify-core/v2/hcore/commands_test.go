package hcore

import (
	"context"
	"errors"
	"fmt"
	"io"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestNormalizeSystemInfoStreamClose(t *testing.T) {
	for _, test := range []struct {
		name   string
		err    error
		normal bool
	}{
		{name: "nil", normal: true},
		{name: "context canceled", err: context.Canceled, normal: true},
		{name: "wrapped context canceled", err: fmt.Errorf("stream: %w", context.Canceled), normal: true},
		{name: "EOF", err: io.EOF, normal: true},
		{name: "wrapped EOF", err: fmt.Errorf("stream: %w", io.EOF), normal: true},
		{name: "gRPC canceled", err: status.Error(codes.Canceled, "client canceled"), normal: true},
		{name: "deadline exceeded is a failure", err: context.DeadlineExceeded},
		{name: "unavailable is a failure", err: status.Error(codes.Unavailable, "transport failure")},
		{name: "ordinary send failure", err: errors.New("write failed")},
	} {
		t.Run(test.name, func(t *testing.T) {
			got := normalizeSystemInfoStreamClose(test.err)
			if test.normal {
				if got != nil {
					t.Fatalf("error = %v, want nil", got)
				}
				return
			}
			if got == nil {
				t.Fatalf("error = nil, want failure %v", test.err)
			}
		})
	}
}

func TestHandleSystemInfoStreamSendErrorPreservesFailures(t *testing.T) {
	failure := errors.New("send failed")
	if got := handleSystemInfoStreamSendError(failure); !errors.Is(got, failure) {
		t.Fatalf("error = %v, want %v", got, failure)
	}
	if got := handleSystemInfoStreamSendError(context.Canceled); got != nil {
		t.Fatalf("canceled stream error = %v, want nil", got)
	}
}
