package test.com.zeon.zeon.bg

import android.content.Context
import com.zeon.zeon.Settings
import com.zeon.zeon.constant.SettingsKey
import org.json.JSONObject

class ProxySelectionPersistenceInstrumentedTest(private val context: Context) {
    fun notificationAutoReplacesDurableManualChoice() {
        val preferences = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        val key = SettingsKey.PENDING_PROXY_SELECTION
        val previous = preferences.getString(key, null)
        try {
            check(preferences.edit().putString(
                key,
                JSONObject().put("group_tag", "select").put("outbound_tag", "manual-a").toString(),
            ).commit())
            check(Settings.persistAutoProxySelection())
            val selected = JSONObject(preferences.getString(key, null) ?: error("selection missing"))
            check(selected.getString("group_tag") == "select")
            check(selected.getString("outbound_tag") == "balance")
        } finally {
            val editor = preferences.edit()
            if (previous == null) editor.remove(key) else editor.putString(key, previous)
            check(editor.commit())
        }
    }
}
