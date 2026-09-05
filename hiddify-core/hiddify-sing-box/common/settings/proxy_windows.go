package settings

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	M "github.com/sagernet/sing/common/metadata"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

const (
	zeonProxyRecoveryKey      = `Software\ZEON\SystemProxyRecovery`
	zeonProxyRunOnceKey       = `Software\Microsoft\Windows\CurrentVersion\RunOnce`
	zeonProxyRunOnceValue     = "ZEONSystemProxyRecovery"
	zeonProxyRecoverySchema   = 1
	internetOptionPerConn     = 75
	internetOptionChanged     = 39
	internetOptionRefresh     = 37
	internetOptionProxyChange = 95
	internetPerConnFlags      = 1
	internetPerConnProxy      = 2
	internetPerConnBypass     = 3
	internetPerConnAutoURL    = 4
	proxyTypeDirect           = 1
	proxyTypeProxy            = 2
)

var (
	proxyOwnershipMu     sync.Mutex
	wininetDLL           = windows.NewLazySystemDLL("wininet.dll")
	internetQueryOptionW = wininetDLL.NewProc("InternetQueryOptionW")
	internetSetOptionW   = wininetDLL.NewProc("InternetSetOptionW")
	kernel32DLL          = windows.NewLazySystemDLL("kernel32.dll")
	globalFree           = kernel32DLL.NewProc("GlobalFree")
)

type windowsProxyState struct {
	Flags         uint32
	ProxyServer   string
	ProxyBypass   string
	AutoConfigURL string
}

type windowsProxyOwnership struct {
	OwnerPID          uint32
	OwnerCreationTime uint64
	Generation        uint64
	MixedPort         uint32
	ExecutablePath    string
	Baseline          windowsProxyState
	Expected          windowsProxyState
}

type internetPerConnOptionList struct {
	Size        uint32
	Connection  uintptr
	OptionCount uint32
	OptionError uint32
	Options     uintptr
}

type internetPerConnOption struct {
	Option uint32
	Value  uintptr
}

type WindowsSystemProxy struct {
	serverAddr   M.Socksaddr
	supportSOCKS bool
	isEnabled    bool
	generation   uint64
}

func NewSystemProxy(ctx context.Context, serverAddr M.Socksaddr, supportSOCKS bool) (*WindowsSystemProxy, error) {
	return &WindowsSystemProxy{
		serverAddr:   serverAddr,
		supportSOCKS: supportSOCKS,
	}, nil
}

func (p *WindowsSystemProxy) IsEnabled() bool {
	return p.isEnabled
}

func (p *WindowsSystemProxy) Enable() error {
	proxyOwnershipMu.Lock()
	defer proxyOwnershipMu.Unlock()

	// Recover an interrupted session before taking a new baseline. If Windows
	// proxy state changed after ZEON armed recovery, only relinquish the stale
	// marker; never overwrite the new foreign/user state.
	if err := recoverOwnedSystemProxy(0); err != nil {
		return fmt.Errorf("recover previous ZEON system proxy: %w", err)
	}

	baseline, err := queryWindowsProxyState()
	if err != nil {
		return fmt.Errorf("capture Windows proxy baseline: %w", err)
	}
	ownerExecutablePath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("resolve ZEON executable: %w", err)
	}
	recoveryExecutablePath, err := proxyRecoveryExecutablePath(ownerExecutablePath, regularFileExists)
	if err != nil {
		return err
	}
	creationTime, err := currentProcessCreationTime()
	if err != nil {
		return fmt.Errorf("read ZEON process identity: %w", err)
	}

	expected := expectedWindowsProxyState(baseline, p.serverAddr.String())
	ownership := windowsProxyOwnership{
		OwnerPID:          uint32(os.Getpid()),
		OwnerCreationTime: creationTime,
		Generation:        newProxyGeneration(),
		MixedPort:         uint32(p.serverAddr.Port),
		ExecutablePath:    recoveryExecutablePath,
		Baseline:          baseline,
		Expected:          expected,
	}

	// Persist ownership and next-logon recovery before changing WinINet. A
	// crash can leave either the unchanged baseline or a fully recoverable
	// ZEON-owned proxy, never an unmarked dead localhost.
	if err := writeProxyOwnership(ownership); err != nil {
		return fmt.Errorf("persist ZEON proxy ownership: %w", err)
	}
	if err := armProxyRunOnce(recoveryExecutablePath); err != nil {
		_ = deleteProxyOwnership()
		return fmt.Errorf("arm ZEON proxy recovery: %w", err)
	}
	if err := setWindowsProxyState(expected); err != nil {
		// InternetSetOption can apply the per-connection state and then fail
		// while broadcasting SETTINGS_CHANGED/REFRESH. Keep recovery armed on
		// every error; a later Disable/startup can then restore the baseline if
		// the exact ZEON state landed, or relinquish a non-matching state.
		return fmt.Errorf("set ZEON system proxy (recovery remains armed): %w", err)
	}

	p.isEnabled = true
	p.generation = ownership.Generation
	return nil
}

func (p *WindowsSystemProxy) Disable() error {
	proxyOwnershipMu.Lock()
	defer proxyOwnershipMu.Unlock()

	if err := recoverOwnedSystemProxy(p.generation); err != nil {
		return fmt.Errorf("restore Windows proxy baseline: %w", err)
	}
	p.isEnabled = false
	p.generation = 0
	return nil
}

func recoverOwnedSystemProxy(expectedGeneration uint64) error {
	ownership, found, err := readProxyOwnership()
	if err != nil {
		return err
	}
	if !found {
		return nil
	}
	// A listener from an older in-process generation may be closed after a
	// replacement listener has already installed a new ZEON proxy. It must not
	// restore that replacement's baseline or disarm its crash recovery.
	if !proxyGenerationMatches(ownership.Generation, expectedGeneration) {
		return nil
	}
	current, err := queryWindowsProxyState()
	if err != nil {
		return err
	}
	if shouldRestoreOwnedProxy(current, ownership.Expected) {
		if err := setWindowsProxyState(ownership.Baseline); err != nil {
			// Keep the marker and RunOnce armed so a later recovery attempt can
			// retry rather than silently abandoning a dead proxy.
			return err
		}
	}
	// A non-matching state is no longer ZEON-owned. Preserve it and discard
	// only our stale recovery record.
	if err := deleteProxyOwnership(); err != nil {
		return err
	}
	return disarmProxyRunOnce()
}

func expectedWindowsProxyState(baseline windowsProxyState, serverAddress string) windowsProxyState {
	expected := baseline
	expected.Flags = proxyTypeDirect | proxyTypeProxy
	expected.ProxyServer = "http://" + serverAddress
	return expected
}

func shouldRestoreOwnedProxy(current, expected windowsProxyState) bool {
	return current == expected
}

func proxyGenerationMatches(recorded, expected uint64) bool {
	return expected == 0 || recorded == expected
}

func proxyRecoveryCommand(executablePath string) string {
	return `"` + executablePath + `" --recover-system-proxy`
}

func regularFileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}

func proxyRecoveryExecutablePath(ownerExecutablePath string, fileExists func(string) bool) (string, error) {
	switch {
	case strings.EqualFold(filepath.Base(ownerExecutablePath), "ZEON.exe"):
		return ownerExecutablePath, nil
	case strings.EqualFold(filepath.Base(ownerExecutablePath), "ZEONCli.exe"):
		runnerPath := filepath.Join(filepath.Dir(ownerExecutablePath), "ZEON.exe")
		if fileExists(runnerPath) {
			return runnerPath, nil
		}
		return "", fmt.Errorf("ZEON system-proxy recovery runner is missing")
	default:
		return "", fmt.Errorf("unsupported ZEON system-proxy owner executable")
	}
}

func queryWindowsProxyState() (windowsProxyState, error) {
	options := []internetPerConnOption{
		{Option: internetPerConnFlags},
		{Option: internetPerConnProxy},
		{Option: internetPerConnBypass},
		{Option: internetPerConnAutoURL},
	}
	list := internetPerConnOptionList{
		Size:        uint32(unsafe.Sizeof(internetPerConnOptionList{})),
		OptionCount: uint32(len(options)),
		Options:     uintptr(unsafe.Pointer(&options[0])),
	}
	length := uint32(unsafe.Sizeof(list))
	r1, _, callErr := internetQueryOptionW.Call(
		0,
		internetOptionPerConn,
		uintptr(unsafe.Pointer(&list)),
		uintptr(unsafe.Pointer(&length)),
	)
	if r1 == 0 {
		return windowsProxyState{}, os.NewSyscallError("InternetQueryOption(PerConnectionOption)", callErr)
	}
	defer freeWinInetString(options[1].Value)
	defer freeWinInetString(options[2].Value)
	defer freeWinInetString(options[3].Value)
	return windowsProxyState{
		Flags:         uint32(options[0].Value),
		ProxyServer:   utf16PointerString(options[1].Value),
		ProxyBypass:   utf16PointerString(options[2].Value),
		AutoConfigURL: utf16PointerString(options[3].Value),
	}, nil
}

func setWindowsProxyState(state windowsProxyState) error {
	proxyServer, err := windows.UTF16PtrFromString(state.ProxyServer)
	if err != nil {
		return err
	}
	proxyBypass, err := windows.UTF16PtrFromString(state.ProxyBypass)
	if err != nil {
		return err
	}
	autoConfigURL, err := windows.UTF16PtrFromString(state.AutoConfigURL)
	if err != nil {
		return err
	}
	options := []internetPerConnOption{
		{Option: internetPerConnFlags, Value: uintptr(state.Flags)},
		{Option: internetPerConnProxy, Value: uintptr(unsafe.Pointer(proxyServer))},
		{Option: internetPerConnBypass, Value: uintptr(unsafe.Pointer(proxyBypass))},
		{Option: internetPerConnAutoURL, Value: uintptr(unsafe.Pointer(autoConfigURL))},
	}
	list := internetPerConnOptionList{
		Size:        uint32(unsafe.Sizeof(internetPerConnOptionList{})),
		OptionCount: uint32(len(options)),
		Options:     uintptr(unsafe.Pointer(&options[0])),
	}
	if err := callInternetSetOption(internetOptionPerConn, uintptr(unsafe.Pointer(&list)), uintptr(list.Size)); err != nil {
		return os.NewSyscallError("InternetSetOption(PerConnectionOption)", err)
	}
	for _, option := range []uintptr{internetOptionChanged, internetOptionProxyChange, internetOptionRefresh} {
		if err := callInternetSetOption(option, 0, 0); err != nil {
			return os.NewSyscallError("InternetSetOption(Refresh)", err)
		}
	}
	return nil
}

func callInternetSetOption(option, buffer, size uintptr) error {
	r1, _, callErr := internetSetOptionW.Call(0, option, buffer, size)
	if r1 == 0 {
		return callErr
	}
	return nil
}

func utf16PointerString(pointer uintptr) string {
	if pointer == 0 {
		return ""
	}
	return windows.UTF16PtrToString((*uint16)(unsafe.Pointer(pointer)))
}

func freeWinInetString(pointer uintptr) {
	if pointer != 0 {
		_, _, _ = globalFree.Call(pointer)
	}
}

func currentProcessCreationTime() (uint64, error) {
	var creation, exit, kernel, user windows.Filetime
	if err := windows.GetProcessTimes(windows.CurrentProcess(), &creation, &exit, &kernel, &user); err != nil {
		return 0, err
	}
	return uint64(creation.HighDateTime)<<32 | uint64(creation.LowDateTime), nil
}

func newProxyGeneration() uint64 {
	var bytes [8]byte
	if _, err := rand.Read(bytes[:]); err == nil {
		if generation := binary.LittleEndian.Uint64(bytes[:]); generation != 0 {
			return generation
		}
	}
	if generation := uint64(time.Now().UnixNano()); generation != 0 {
		return generation
	}
	return 1
}

func writeProxyOwnership(value windowsProxyOwnership) error {
	_ = registry.DeleteKey(registry.CURRENT_USER, zeonProxyRecoveryKey)
	key, _, err := registry.CreateKey(registry.CURRENT_USER, zeonProxyRecoveryKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	// Explicitly invalidate an existing/partially written key before replacing
	// its fields. This keeps Armed as a real commit marker even if a stale key
	// could not be deleted atomically before CreateKey reopened it.
	if err := key.SetDWordValue("Armed", 0); err != nil {
		return err
	}
	writes := []error{
		key.SetDWordValue("Schema", zeonProxyRecoverySchema),
		key.SetDWordValue("OwnerPid", value.OwnerPID),
		key.SetQWordValue("OwnerCreationTime", value.OwnerCreationTime),
		key.SetQWordValue("Generation", value.Generation),
		key.SetDWordValue("MixedPort", value.MixedPort),
		key.SetStringValue("ExecutablePath", value.ExecutablePath),
		writeStoredProxyState(key, "Baseline", value.Baseline),
		writeStoredProxyState(key, "Expected", value.Expected),
	}
	for _, writeErr := range writes {
		if writeErr != nil {
			_ = deleteProxyOwnership()
			return writeErr
		}
	}
	return key.SetDWordValue("Armed", 1)
}

func writeStoredProxyState(key registry.Key, prefix string, state windowsProxyState) error {
	if err := key.SetDWordValue(prefix+"Flags", state.Flags); err != nil {
		return err
	}
	if err := key.SetStringValue(prefix+"ProxyServer", state.ProxyServer); err != nil {
		return err
	}
	if err := key.SetStringValue(prefix+"ProxyBypass", state.ProxyBypass); err != nil {
		return err
	}
	return key.SetStringValue(prefix+"AutoConfigURL", state.AutoConfigURL)
}

func readProxyOwnership() (windowsProxyOwnership, bool, error) {
	key, err := registry.OpenKey(registry.CURRENT_USER, zeonProxyRecoveryKey, registry.QUERY_VALUE)
	if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) {
		return windowsProxyOwnership{}, false, nil
	}
	if err != nil {
		return windowsProxyOwnership{}, false, err
	}
	defer key.Close()
	armed, _, err := key.GetIntegerValue("Armed")
	if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) || armed != 1 {
		// Armed is written last, before RunOnce and before WinINet changes. A
		// partial record therefore cannot represent an applied ZEON proxy.
		return windowsProxyOwnership{}, false, nil
	}
	if err != nil {
		return windowsProxyOwnership{}, false, err
	}
	schema, _, err := key.GetIntegerValue("Schema")
	if err != nil || schema != zeonProxyRecoverySchema {
		return windowsProxyOwnership{}, false, fmt.Errorf("unsupported ZEON proxy recovery schema")
	}
	ownerPID, _, err := key.GetIntegerValue("OwnerPid")
	if err != nil {
		return windowsProxyOwnership{}, false, err
	}
	ownerCreationTime, _, err := key.GetIntegerValue("OwnerCreationTime")
	if err != nil {
		return windowsProxyOwnership{}, false, err
	}
	generation, _, err := key.GetIntegerValue("Generation")
	if err != nil {
		return windowsProxyOwnership{}, false, err
	}
	mixedPort, _, err := key.GetIntegerValue("MixedPort")
	if err != nil {
		return windowsProxyOwnership{}, false, err
	}
	executablePath, _, err := key.GetStringValue("ExecutablePath")
	if err != nil {
		return windowsProxyOwnership{}, false, err
	}
	baseline, err := readStoredProxyState(key, "Baseline")
	if err != nil {
		return windowsProxyOwnership{}, false, err
	}
	expected, err := readStoredProxyState(key, "Expected")
	if err != nil {
		return windowsProxyOwnership{}, false, err
	}
	return windowsProxyOwnership{
		OwnerPID:          uint32(ownerPID),
		OwnerCreationTime: ownerCreationTime,
		Generation:        generation,
		MixedPort:         uint32(mixedPort),
		ExecutablePath:    executablePath,
		Baseline:          baseline,
		Expected:          expected,
	}, true, nil
}

func readStoredProxyState(key registry.Key, prefix string) (windowsProxyState, error) {
	flags, _, err := key.GetIntegerValue(prefix + "Flags")
	if err != nil {
		return windowsProxyState{}, err
	}
	server, _, err := key.GetStringValue(prefix + "ProxyServer")
	if err != nil {
		return windowsProxyState{}, err
	}
	bypass, _, err := key.GetStringValue(prefix + "ProxyBypass")
	if err != nil {
		return windowsProxyState{}, err
	}
	autoURL, _, err := key.GetStringValue(prefix + "AutoConfigURL")
	if err != nil {
		return windowsProxyState{}, err
	}
	return windowsProxyState{
		Flags:         uint32(flags),
		ProxyServer:   server,
		ProxyBypass:   bypass,
		AutoConfigURL: autoURL,
	}, nil
}

func deleteProxyOwnership() error {
	err := registry.DeleteKey(registry.CURRENT_USER, zeonProxyRecoveryKey)
	if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) {
		return nil
	}
	return err
}

func armProxyRunOnce(executablePath string) error {
	key, _, err := registry.CreateKey(registry.CURRENT_USER, zeonProxyRunOnceKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	return key.SetStringValue(zeonProxyRunOnceValue, proxyRecoveryCommand(executablePath))
}

func disarmProxyRunOnce() error {
	key, err := registry.OpenKey(registry.CURRENT_USER, zeonProxyRunOnceKey, registry.SET_VALUE)
	if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) {
		return nil
	}
	if err != nil {
		return err
	}
	defer key.Close()
	err = key.DeleteValue(zeonProxyRunOnceValue)
	if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) {
		return nil
	}
	return err
}
