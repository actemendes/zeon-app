# ZEON application-specific R8 rules.
#
# Generated Flutter plugin registration, MethodChannel handlers, gomobile/JNI
# and serialization are covered by direct references or dependency consumer
# rules. Do not add package-wide keep rules here.

# ZEON paints system-bar surfaces in Flutter and sends icon appearance only.
# MaterialDatePicker is not used and its originating Material dependency is
# removed. The Flutter 3.41.9 embedding nevertheless contains compatibility
# branches for these deprecated setters. Treating the setters as side-effect
# free lets R8 erase those now-unreachable color writes from the production DEX.
# scripts/verify_android_window_api_refs.ps1 is the fail-closed artifact gate.
-assumenosideeffects class android.view.Window {
    public void setStatusBarColor(int);
    public void setNavigationBarColor(int);
    public void setNavigationBarDividerColor(int);
}
