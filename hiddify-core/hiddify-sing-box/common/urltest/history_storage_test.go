package urltest

import (
	"sync"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/hiddify/ipinfo"
	"github.com/sagernet/sing/common/observable"
)

func TestHistoryStoragePublishedSnapshotIsImmutable(t *testing.T) {
	storage := NewHistoryStorage()
	first := &adapter.URLTestHistory{
		Time: time.Unix(1, 0), Delay: 20, Success: true,
		HealthScore: 91, CheckGeneration: 1,
		IpInfo: &ipinfo.IpInfo{CountryCode: "AA"},
	}
	published := storage.StoreURLTestHistory("node", first)
	storage.StoreURLTestHistory("node", &adapter.URLTestHistory{
		Time: time.Unix(2, 0), Delay: 80, Success: false,
		HealthScore: 17, CheckGeneration: 2,
		IpInfo: &ipinfo.IpInfo{CountryCode: "BB"},
	})

	if published.Delay != 20 || published.HealthScore != 91 || published.CheckGeneration != 1 {
		t.Fatalf("published snapshot changed after later store: %+v", published)
	}
	if published.IpInfo == nil || published.IpInfo.CountryCode != "AA" {
		t.Fatalf("published nested snapshot changed after later store: %+v", published.IpInfo)
	}
}

func TestHistoryStorageDoesNotRetainCallerOwnedObject(t *testing.T) {
	storage := NewHistoryStorage()
	input := &adapter.URLTestHistory{
		Delay:  40,
		IpInfo: &ipinfo.IpInfo{CountryCode: "AA"},
	}
	storage.StoreURLTestHistory("node", input)
	input.Delay = 999
	input.IpInfo.CountryCode = "ZZ"

	stored := storage.LoadURLTestHistory("node")
	if stored.Delay != 40 || stored.IpInfo == nil || stored.IpInfo.CountryCode != "AA" {
		t.Fatalf("caller mutation leaked into storage: %+v", stored)
	}
}

func TestHistoryStorageLoadReturnsDetachedSnapshot(t *testing.T) {
	storage := NewHistoryStorage()
	storage.StoreURLTestHistory("node", &adapter.URLTestHistory{
		Delay:  50,
		IpInfo: &ipinfo.IpInfo{CountryCode: "AA"},
	})
	loaded := storage.LoadURLTestHistory("node")
	loaded.Delay = 777
	loaded.IpInfo.CountryCode = "ZZ"

	reloaded := storage.LoadURLTestHistory("node")
	if reloaded.Delay != 50 || reloaded.IpInfo == nil || reloaded.IpInfo.CountryCode != "AA" {
		t.Fatalf("loaded snapshot retained storage ownership: %+v", reloaded)
	}
}

func TestHistoryStorageConcurrentReadersAndWriter(t *testing.T) {
	storage := NewHistoryStorage()
	storage.StoreURLTestHistory("node", &adapter.URLTestHistory{Delay: 1})
	const iterations = 500
	const readers = 8

	var wg sync.WaitGroup
	wg.Add(readers + 1)
	for reader := 0; reader < readers; reader++ {
		go func() {
			defer wg.Done()
			for index := 0; index < iterations; index++ {
				history := storage.LoadURLTestHistory("node")
				if history == nil {
					t.Errorf("reader observed nil history")
					return
				}
				_ = history.Delay
			}
		}()
	}
	go func() {
		defer wg.Done()
		for index := 0; index < iterations; index++ {
			storage.StoreURLTestHistory("node", &adapter.URLTestHistory{
				Delay: uint16(index + 1), CheckGeneration: uint64(index + 1),
			})
		}
	}()
	wg.Wait()
}

func TestHistoryStorageCloseDuringPublication(t *testing.T) {
	storage := NewHistoryStorage()
	hook := observable.NewSubscriber[struct{}](1)
	storage.SetHook(hook)

	publicationDone := make(chan struct{})
	go func() {
		storage.StoreURLTestHistory("node", &adapter.URLTestHistory{Delay: 10})
		close(publicationDone)
	}()
	if err := storage.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-publicationDone:
	case <-time.After(time.Second):
		t.Fatal("publication deadlocked with Close")
	}
}
