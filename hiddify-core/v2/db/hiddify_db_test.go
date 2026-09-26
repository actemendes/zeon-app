package db

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	leveldberrors "github.com/syndtr/goleveldb/leveldb/errors"
	tmdb "github.com/tendermint/tm-db"
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

func TestCorruptedManifestDoesNotConsumeDatabaseRetryWindow(t *testing.T) {
	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(previous); err != nil {
			t.Error(err)
		}
	})

	initial, err := tmdb.NewGoLevelDBWithOpts("corrupted", "./data", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := initial.Close(); err != nil {
		t.Fatal(err)
	}
	manifests, err := filepath.Glob(filepath.Join("data", "corrupted.db", "MANIFEST-*"))
	if err != nil || len(manifests) != 1 {
		t.Fatalf("manifest lookup: %v, matches=%d", err, len(manifests))
	}
	if err := os.WriteFile(manifests[0], bytes.Repeat([]byte{0}, 673), 0600); err != nil {
		t.Fatal(err)
	}

	started := time.Now()
	opened, err := openDB("corrupted", false)
	if opened != nil {
		_ = opened.Close()
		t.Fatal("corrupted database unexpectedly opened")
	}
	if !leveldberrors.IsCorrupted(err) {
		t.Fatalf("expected corruption error, got %v", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("corrupted database open took %v; expected no retry window", elapsed)
	}
}
