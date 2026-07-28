package interrupt

import (
	"io"
	"net"
	"sync"

	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/common/x/list"
)

type Group struct {
	access      sync.Mutex
	connections list.List[*groupConnItem]
}

type groupConnItem struct {
	conn       io.Closer
	isExternal bool
	network    string
}

type Result struct {
	ClosedTCP      int
	ClosedUDP      int
	ClosedExternal int
}

func NewGroup() *Group {
	return &Group{}
}

func (g *Group) NewConn(conn net.Conn, isExternal bool) net.Conn {
	g.access.Lock()
	defer g.access.Unlock()
	item := g.connections.PushBack(&groupConnItem{conn: conn, isExternal: isExternal, network: "tcp"})
	return &Conn{Conn: conn, group: g, element: item}
}

func (g *Group) NewPacketConn(conn net.PacketConn, isExternal bool) net.PacketConn {
	g.access.Lock()
	defer g.access.Unlock()
	item := g.connections.PushBack(&groupConnItem{conn: conn, isExternal: isExternal, network: "udp"})
	return &PacketConn{PacketConn: conn, group: g, element: item}
}

func (g *Group) NewSingPacketConn(conn N.PacketConn, isExternal bool) N.PacketConn {
	g.access.Lock()
	defer g.access.Unlock()
	item := g.connections.PushBack(&groupConnItem{conn: conn, isExternal: isExternal, network: "udp"})
	return &SingPacketConn{PacketConn: conn, group: g, element: item}
}

func (g *Group) Interrupt(interruptExternalConnections bool) Result {
	g.access.Lock()
	defer g.access.Unlock()
	var result Result
	var toDelete []*list.Element[*groupConnItem]
	for element := g.connections.Front(); element != nil; element = element.Next() {
		if !element.Value.isExternal || interruptExternalConnections {
			element.Value.conn.Close()
			toDelete = append(toDelete, element)
			if element.Value.network == "udp" {
				result.ClosedUDP++
			} else {
				result.ClosedTCP++
			}
			if element.Value.isExternal {
				result.ClosedExternal++
			}
		}
	}
	for _, element := range toDelete {
		g.connections.Remove(element)
	}
	return result
}
