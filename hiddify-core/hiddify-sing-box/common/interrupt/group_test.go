package interrupt

import (
	"net"
	"testing"
)

func TestInterruptPreservesExternalTCPAndUDP(t *testing.T) {
	group := NewGroup()
	externalTCP, externalTCPPeer := net.Pipe()
	internalTCP, internalTCPPeer := net.Pipe()
	externalUDP, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	internalUDP, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer externalTCPPeer.Close()
	defer internalTCPPeer.Close()
	group.NewConn(externalTCP, true)
	group.NewConn(internalTCP, false)
	group.NewPacketConn(externalUDP, true)
	group.NewPacketConn(internalUDP, false)

	result := group.Interrupt(false)
	if result.ClosedTCP != 1 || result.ClosedUDP != 1 || result.ClosedExternal != 0 {
		t.Fatalf("preserve result=%+v", result)
	}

	result = group.Interrupt(true)
	if result.ClosedTCP != 1 || result.ClosedUDP != 1 || result.ClosedExternal != 2 {
		t.Fatalf("emergency result=%+v", result)
	}
}
