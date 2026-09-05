//go:build with_gvisor

package tun

import (
	"github.com/sagernet/gvisor/pkg/tcpip/stack"
	"testing"
)

type recordingEndpoint struct {
	stack.LinkEndpoint
	dispatcher stack.NetworkDispatcher
}

func (e *recordingEndpoint) Attach(dispatcher stack.NetworkDispatcher) {
	e.dispatcher = dispatcher
}

type testNetworkDispatcher struct{ stack.NetworkDispatcher }

func TestFilterPreservesDetachSignal(t *testing.T) {
	endpoint := new(recordingEndpoint)
	filter := &LinkEndpointFilter{LinkEndpoint: endpoint}
	filter.Attach(new(testNetworkDispatcher))
	if endpoint.dispatcher == nil {
		t.Fatal("live dispatcher was not attached")
	}
	filter.Attach(nil)
	if endpoint.dispatcher != nil {
		t.Fatal("nil detach was wrapped as a live dispatcher")
	}
}
