package db

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

type cachedSettingsRecord struct {
	Id    string
	Value string
}

func TestSettingsReadsAndWritesReuseOneDatabase(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("Windows database lifetime")
	}
	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	working := t.TempDir()
	if err := os.Chdir(working); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		path := filepath.Join(working, "data", "cachedSettingsRecord.db")
		databaseCache.Lock()
		if db := databaseCache.byPath[path]; db != nil {
			if err := db.Close(); err != nil {
				t.Error(err)
			}
			delete(databaseCache.byPath, path)
		}
		databaseCache.Unlock()
		if err := os.Chdir(previous); err != nil {
			t.Error(err)
		}
	})

	table := GetTable[cachedSettingsRecord]()
	first, err := getDB(table.name, true)
	if err != nil {
		t.Fatal(err)
	}
	if err := table.UpdateInsert(&cachedSettingsRecord{Id: "setting", Value: "new"}); err != nil {
		t.Fatal(err)
	}
	second, err := getDB(table.name, false)
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatal("settings database was reopened between a read and a write")
	}
	got, err := table.Get("setting")
	if err != nil {
		t.Fatal(err)
	}
	if got.Value != "new" {
		t.Fatalf("stored setting = %q", got.Value)
	}
}
