//go:build with_gvisor && linux

package tun

import (
	"github.com/sagernet/gvisor/pkg/tcpip/link/fdbased"
	"golang.org/x/sys/unix"
	"testing"
	"time"
)

func TestFilterDetachStopsNativePolling(t *testing.T) {
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM|unix.SOCK_NONBLOCK, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fds[0])
	defer unix.Close(fds[1])
	endpoint, err := fdbased.New(&fdbased.Options{FDs: []int{fds[0]}, MTU: 1500})
	if err != nil {
		t.Fatal(err)
	}
	// Direct cleanup keeps the failing regression test from leaking its reader.
	defer endpoint.Attach(nil)
	filter := &LinkEndpointFilter{LinkEndpoint: endpoint}
	filter.Attach(new(testNetworkDispatcher))
	filter.Attach(nil)
	stopped := make(chan struct{})
	go func() { endpoint.Wait(); close(stopped) }()
	select {
	case <-stopped:
	case <-time.After(time.Second):
		t.Fatal("native reader survives filtered detach and retains its polling resources")
	}
}
