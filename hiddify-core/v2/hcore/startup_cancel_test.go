package hcore

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestCancelledRPCNeverEntersStartup(t *testing.T) {
	old := static.BaseContext
	static.BaseContext = context.Background()
	defer func() { static.BaseContext = old }()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := (&CoreService{}).Start(ctx, &StartRequest{})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v, want cancelled request", err)
	}
}

func TestStopCancelsStartupBeforeWaitingForCoreLock(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	static.startupAccess.Lock()
	static.startupCancel = cancel
	static.startupAccess.Unlock()
	static.lock.Lock()
	done := make(chan struct{})
	go func() { Stop(); close(done) }()
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		static.lock.Unlock()
		<-done
		t.Fatal("stop waited behind startup without cancelling it")
	}
	static.lock.Unlock()
	<-done
}
