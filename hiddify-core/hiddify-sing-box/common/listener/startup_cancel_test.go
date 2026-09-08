package listener

import (
	"context"
	"errors"
	"github.com/sagernet/sing-box/log"
	N "github.com/sagernet/sing/common/network"
	"testing"
)

func TestCancelledStartupDoesNotOpenListenerOrEnableProxy(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	l := New(Options{Context: ctx, Logger: log.NewNOPFactory().Logger(), Network: []string{N.NetworkTCP}, SetSystemProxy: true})
	if err := l.Start(); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
	if l.tcpListener != nil || l.systemProxy != nil {
		t.Fatal("cancelled startup acquired resources")
	}
	retry := New(Options{Context: context.Background(), Logger: log.NewNOPFactory().Logger(), Network: []string{N.NetworkTCP}})
	if err := retry.Start(); err != nil {
		t.Fatal(err)
	}
	if retry.tcpListener == nil {
		t.Fatal("retry did not open its listener")
	}
	if err := retry.Close(); err != nil {
		t.Fatal(err)
	}
}
