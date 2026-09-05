package settings

import "testing"

func TestExpectedWindowsProxyStatePreservesInactiveBaselineFields(t *testing.T) {
	baseline := windowsProxyState{
		Flags:         13,
		ProxyServer:   "http://corp.example:8080",
		ProxyBypass:   "*.corp.example;<local>",
		AutoConfigURL: "https://corp.example/proxy.pac",
	}
	expected := expectedWindowsProxyState(baseline, "127.0.0.1:12346")
	if expected.Flags != proxyTypeDirect|proxyTypeProxy {
		t.Fatalf("unexpected flags: %d", expected.Flags)
	}
	if expected.ProxyServer != "http://127.0.0.1:12346" {
		t.Fatalf("unexpected proxy server: %q", expected.ProxyServer)
	}
	if expected.ProxyBypass != baseline.ProxyBypass || expected.AutoConfigURL != baseline.AutoConfigURL {
		t.Fatal("ZEON state did not preserve baseline bypass/PAC values")
	}
	if baseline.ProxyServer != "http://corp.example:8080" || baseline.Flags != 13 {
		t.Fatal("baseline was mutated")
	}
}

func TestOwnedProxyRequiresExactCurrentState(t *testing.T) {
	expected := windowsProxyState{
		Flags:         3,
		ProxyServer:   "http://127.0.0.1:12346",
		ProxyBypass:   "<local>",
		AutoConfigURL: "https://corp.example/proxy.pac",
	}
	if !shouldRestoreOwnedProxy(expected, expected) {
		t.Fatal("exact ZEON-owned state should restore")
	}
	mutations := []windowsProxyState{
		{Flags: 1, ProxyServer: expected.ProxyServer, ProxyBypass: expected.ProxyBypass, AutoConfigURL: expected.AutoConfigURL},
		{Flags: expected.Flags, ProxyServer: "http://foreign.example:8080", ProxyBypass: expected.ProxyBypass, AutoConfigURL: expected.AutoConfigURL},
		{Flags: expected.Flags, ProxyServer: expected.ProxyServer, ProxyBypass: "*.new.example", AutoConfigURL: expected.AutoConfigURL},
		{Flags: expected.Flags, ProxyServer: expected.ProxyServer, ProxyBypass: expected.ProxyBypass, AutoConfigURL: "https://policy.example/new.pac"},
	}
	for index, current := range mutations {
		if shouldRestoreOwnedProxy(current, expected) {
			t.Fatalf("foreign mutation %d was incorrectly treated as ZEON-owned", index)
		}
	}
}

func TestRecoveryCommandQuotesExecutablePath(t *testing.T) {
	got := proxyRecoveryCommand(`C:\Program Files\ZEON\ZEON.exe`)
	want := `"C:\Program Files\ZEON\ZEON.exe" --recover-system-proxy`
	if got != want {
		t.Fatalf("unexpected RunOnce command: %q", got)
	}
}

func TestProxyRecoveryExecutableUsesRunnerForCliOwner(t *testing.T) {
	owner := `C:\Program Files\ZEON\ZEONCli.exe`
	want := `C:\Program Files\ZEON\ZEON.exe`
	got, err := proxyRecoveryExecutablePath(owner, func(path string) bool {
		return path == want
	})
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("unexpected recovery runner: %q", got)
	}
}

func TestProxyRecoveryExecutableFailsClosedWithoutRunner(t *testing.T) {
	_, err := proxyRecoveryExecutablePath(
		`C:\portable\ZEONCli.exe`, func(string) bool { return false })
	if err == nil {
		t.Fatal("CLI system proxy must not arm an unusable recovery command")
	}
}

func TestProxyRecoveryExecutableKeepsGuiRunner(t *testing.T) {
	want := `C:\Program Files\ZEON\ZEON.exe`
	got, err := proxyRecoveryExecutablePath(want, func(string) bool { return false })
	if err != nil || got != want {
		t.Fatalf("unexpected GUI recovery runner result: path=%q err=%v", got, err)
	}
}

func TestOldProxyInstanceCannotClaimReplacementGeneration(t *testing.T) {
	if proxyGenerationMatches(42, 41) {
		t.Fatal("an old proxy instance claimed the replacement generation")
	}
	if !proxyGenerationMatches(42, 42) {
		t.Fatal("the owning proxy instance did not match its generation")
	}
	if !proxyGenerationMatches(42, 0) {
		t.Fatal("startup recovery must be able to inspect any generation")
	}
}
