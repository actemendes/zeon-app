package db

import (
	"bytes"
	"encoding/gob"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sync"
	"time"

	leveldberrors "github.com/syndtr/goleveldb/leveldb/errors"
	"github.com/syndtr/goleveldb/leveldb/opt"
	tmdb "github.com/tendermint/tm-db"
)

var databaseCache = struct {
	sync.Mutex
	byPath map[string]tmdb.DB
}{byPath: make(map[string]tmdb.DB)}

// getDB keeps one writable LevelDB handle per database on Windows.
// Reopening and closing on every settings access creates a new L0 table and can
// make Close wait tens of seconds for compaction on long-lived Windows installs.
func getDB(name string, readOnly bool) (tmdb.DB, error) {
	if runtime.GOOS != "windows" {
		return openDB(name, readOnly)
	}
	dbPath, err := filepath.Abs(filepath.Join("data", name+".db"))
	if err != nil {
		return nil, err
	}
	databaseCache.Lock()
	defer databaseCache.Unlock()
	if db := databaseCache.byPath[dbPath]; db != nil {
		return db, nil
	}
	// Callers that initially read settings may later write them. A cached
	// read-only handle would make that normal transition fail.
	db, err := openDB(name, false)
	if err != nil {
		return nil, err
	}
	databaseCache.byPath[dbPath] = db
	return db, nil
}

func openDB(name string, readOnly bool) (tmdb.DB, error) {
	dbPath := "data/" + name + ".db"
	if _, err := os.Stat(dbPath); os.IsNotExist(err) {
		readOnly = false
	}
	const retryAttempts = 100
	const retryDelay = 50 * time.Millisecond

	var db tmdb.DB
	var err error
	defer func() {
		if r := recover(); r != nil {
			log.Printf("Recovered from panic: %v", r)
		}
	}()
	for i := 0; i < retryAttempts; i++ {
		opts := &opt.Options{ReadOnly: readOnly && i < 80}

		db, err = tmdb.NewGoLevelDBWithOpts(name, "./data", opts)
		if err == nil {
			return db, nil
		}
		// A damaged manifest cannot become readable after a short delay. Retrying
		// it 100 times blocks every settings read/write for about five seconds.
		if leveldberrors.IsCorrupted(err) {
			return nil, err
		}
		log.Printf("Failed attempt %d to initialize the database: %v", i, err)
		time.Sleep(retryDelay)
	}
	return nil, err
}

func closeAfterUse(db tmdb.DB) {
	if runtime.GOOS != "windows" {
		_ = db.Close()
	}
}

// GetTable returns a new Table instance for the generic type T, ensuring the struct has an "Id" field.
func GetTable[T any]() *Table[T] {
	var t T
	typeName := reflect.TypeOf(t).Name()
	if !hasIdField(t) {
		panic(fmt.Sprintf("Table %s must have a field named 'Id'", typeName))
	}
	return &Table[T]{name: typeName}
}

// hasIdField checks if the struct has a field named "Id".
func hasIdField[T any](t T) bool {
	val := reflect.Indirect(reflect.ValueOf(t))

	if val.Kind() != reflect.Struct {
		return false
	}

	return val.FieldByName("Id").IsValid()
}

// getIdBytes converts an ID to its byte representation for storage in the database.
func getIdBytes(id any) []byte {
	res, err := SerializeKey(id)
	if err != nil {
		return nil
	}
	return res
}

// 	if id == nil {
// 		return nil
// 	}

// 	var buf bytes.Buffer
// 	switch v := id.(type) {
// 	case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
// 		if err := binary.Write(&buf, binary.BigEndian, v); err == nil {
// 			return buf.Bytes()
// 		}
// 	case string:
// 		return []byte(v)
// 	case []byte:
// 		return v
// 	default:
// 		return []byte(fmt.Sprint(v))
// 	}
// 	return nil
// }

// getId retrieves the "Id" field from the struct T.
func getId[T any](t T) any {
	val := reflect.Indirect(reflect.ValueOf(t))

	if val.Kind() != reflect.Struct {
		return nil
	}

	field := val.FieldByName("Id")
	if field.IsValid() {
		return field.Interface()
	}
	return nil
}

// Table represents a database table for generic type T.
type Table[T any] struct {
	name string
}

// All retrieves all entries from the database and unmarshals them into a slice of T.
func (tbl *Table[T]) All() ([]*T, error) {
	db, err := getDB(tbl.name, true)
	if db == nil {
		return nil, fmt.Errorf("failed to open database %s, error: %w", tbl.name, err)
	}
	defer closeAfterUse(db)

	var items []*T
	iter, err := db.Iterator(nil, nil)
	if err != nil {
		return nil, err
	}
	defer iter.Close()

	for ; iter.Valid(); iter.Next() {

		item, err := Deserialize[T](iter.Value())
		if err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, nil
}

func Serialize(data any) ([]byte, error) {
	var buf bytes.Buffer
	enc := gob.NewEncoder(&buf)
	err := enc.Encode(data)
	return buf.Bytes(), err

	// return json.Marshal(data)
}

func SerializeKey(data any) ([]byte, error) {
	var buf bytes.Buffer
	enc := gob.NewEncoder(&buf)
	err := enc.Encode(data)
	return buf.Bytes(), err
}

func Deserialize[T any](data []byte) (*T, error) {
	var obj T
	buf := bytes.NewBuffer(data)
	dec := gob.NewDecoder(buf)
	err := dec.Decode(&obj)
	return &obj, err

	// return &obj, json.Unmarshal(data, &obj)
}

// UpdateInsert inserts or updates multiple items in the database.
func (tbl *Table[T]) UpdateInsert(items ...*T) error {
	db, err := getDB(tbl.name, false)
	if db == nil {
		return fmt.Errorf("failed to open database %s, error: %w", tbl.name, err)
	}
	defer closeAfterUse(db)

	for _, item := range items {
		// b, err := json.Marshal(item)
		b, err := Serialize(item)
		if err != nil {
			return err
		}
		if err := db.Set(getIdBytes(getId(item)), b); err != nil {
			return err
		}
	}
	return nil
}

// Delete removes entries by their IDs.
func (tbl *Table[T]) Delete(ids ...any) error {
	db, err := getDB(tbl.name, false)
	if db == nil {
		return fmt.Errorf("failed to open database %s, error: %w", tbl.name, err)
	}
	defer closeAfterUse(db)

	for _, id := range ids {
		if err := db.Delete(getIdBytes(id)); err != nil {
			return err
		}
	}
	return nil
}

// Get retrieves a single item by its ID.
func (tbl *Table[T]) Get(id any) (*T, error) {
	db, err := getDB(tbl.name, true)
	if db == nil {
		return nil, fmt.Errorf("failed to open database %s, error: %w", tbl.name, err)
	}
	defer closeAfterUse(db)

	b, err := db.Get(getIdBytes(id))
	if err != nil {
		return nil, err
	}
	return Deserialize[T](b)
}
