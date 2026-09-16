package com.zeon.zeon

import android.content.Context
import android.util.Base64
import com.zeon.zeon.bg.VPNService
import com.zeon.zeon.constant.PerAppProxyMode
import com.zeon.zeon.constant.ServiceMode
import com.zeon.zeon.constant.SettingsKey
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ObjectInputStream


object Settings {

    private val preferences by lazy {
        val context = Application.application.applicationContext
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    }

    private const val LIST_IDENTIFIER = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"

    var perAppProxyMode: String
        get() = preferences.getString(SettingsKey.PER_APP_PROXY_MODE, PerAppProxyMode.OFF)!!
        set(value) = preferences.edit().putString(SettingsKey.PER_APP_PROXY_MODE, value).apply()

    val perAppProxyEnabled: Boolean
        get() = perAppProxyMode != PerAppProxyMode.OFF

    val hasPerAppProxyConflict: Boolean
        get() {
            val includeRaw = preferences.getString(SettingsKey.PER_APP_PROXY_INCLUDE_LIST, "") ?: ""
            val excludeRaw = preferences.getString(SettingsKey.PER_APP_PROXY_EXCLUDE_LIST, "") ?: ""
            return includeRaw.isNotBlank() && excludeRaw.isNotBlank() && perAppProxyMode != PerAppProxyMode.OFF
        }

    val perAppProxyList: List<String>
        get() {
            val stringValue = if (perAppProxyMode == PerAppProxyMode.INCLUDE) {
                preferences.getString(SettingsKey.PER_APP_PROXY_INCLUDE_LIST, "")!!
            } else {
                preferences.getString(SettingsKey.PER_APP_PROXY_EXCLUDE_LIST, "")!!
            }
            if (!stringValue.startsWith(LIST_IDENTIFIER)) {
                return stringValue.split(";")
            }
            return try {
                decodeListString(stringValue.substring(LIST_IDENTIFIER.length))
            } catch (e: java.lang.Exception) {
                emptyList()
            }
        }

    private fun decodeListString(listString: String): List<String> {
        val stream = ObjectInputStream(ByteArrayInputStream(Base64.decode(listString, 0)))
        return stream.readObject() as List<String>
    }

    var activeConfigPath: String
        get() = preferences.getString(SettingsKey.ACTIVE_CONFIG_PATH, "")!!
        set(value) = preferences.edit().putString(SettingsKey.ACTIVE_CONFIG_PATH, value).apply()

    var activeProfileName: String
        get() = preferences.getString(SettingsKey.ACTIVE_PROFILE_NAME, "")!!
        set(value) = preferences.edit().putString(SettingsKey.ACTIVE_PROFILE_NAME, value).apply()

    /** Keep notification Auto selection as the next-start Flutter selector intent. */
    fun persistAutoProxySelection(): Boolean = preferences.edit().putString(
        SettingsKey.PENDING_PROXY_SELECTION,
        JSONObject().put("group_tag", "select").put("outbound_tag", "balance").toString(),
    ).commit()

    var serviceMode: String
        get() {
            val storedMode = preferences.getString(SettingsKey.SERVICE_MODE, ServiceMode.VPN)
            val canonicalMode = ServiceMode.canonicalize(storedMode)
            if (storedMode != canonicalMode) {
                preferences.edit().putString(SettingsKey.SERVICE_MODE, canonicalMode).apply()
            }
            return canonicalMode
        }
        set(@Suppress("UNUSED_PARAMETER") value) =
            preferences.edit().putString(SettingsKey.SERVICE_MODE, ServiceMode.VPN).apply()

    var configOptions: String
        get() = preferences.getString(SettingsKey.CONFIG_OPTIONS, "")!!
        set(value) = preferences.edit().putString(SettingsKey.CONFIG_OPTIONS, value).apply()

    var debugMode: Boolean
        get() = preferences.getBoolean(SettingsKey.DEBUG_MODE, false)
        set(value) = preferences.edit().putBoolean(SettingsKey.DEBUG_MODE, value).apply()

    var disableMemoryLimit: Boolean
        get() = preferences.getBoolean(SettingsKey.DISABLE_MEMORY_LIMIT, false)
        set(value) =
            preferences.edit().putBoolean(SettingsKey.DISABLE_MEMORY_LIMIT, value).apply()

    var dynamicNotification: Boolean
        get() = preferences.getBoolean(SettingsKey.DYNAMIC_NOTIFICATION, true)
        set(value) =
            preferences.edit().putBoolean(SettingsKey.DYNAMIC_NOTIFICATION, value).apply()

    var systemProxyEnabled: Boolean
        get() = preferences.getBoolean(SettingsKey.SYSTEM_PROXY_ENABLED, true)
        set(value) =
            preferences.edit().putBoolean(SettingsKey.SYSTEM_PROXY_ENABLED, value).apply()

    var startedByUser: Boolean
        get() = preferences.getBoolean(SettingsKey.STARTED_BY_USER, false)
        set(value) = preferences.edit().putBoolean(SettingsKey.STARTED_BY_USER, value).apply()

    fun serviceClass(): Class<*> = VPNService::class.java

    private var currentServiceMode : String? = null

    suspend fun rebuildServiceMode(): Boolean {
        val newMode = serviceMode
        if (currentServiceMode == newMode) {
            return false
        }
        currentServiceMode = newMode
        return true
    }

    var workingDir: String
        get() = preferences.getString(SettingsKey.WORKING_DIR, "./")!!
        set(value) = preferences.edit().putString(SettingsKey.WORKING_DIR, value).apply()
    var tempDir: String
        get() = preferences.getString(SettingsKey.TMP_DIR, "./")!!
        set(value) = preferences.edit().putString(SettingsKey.TMP_DIR, value).apply()

    var baseDir: String
        get() = preferences.getString(SettingsKey.BASE_DIR, "./")!!
        set(value) = preferences.edit().putString(SettingsKey.BASE_DIR, value).apply()



    var grpcFlutterPublicKey: ByteArray
        get() {
            val encoded = preferences.getString(SettingsKey.GRPC_FLUTTER_PUBLIC_KEY, null)
            return encoded?.let { Base64.decode(it, Base64.DEFAULT) } ?: ByteArray(0)
        }
        set(value) {
            val encoded = Base64.encodeToString(value, Base64.DEFAULT)
            preferences.edit().putString(SettingsKey.GRPC_FLUTTER_PUBLIC_KEY, encoded).apply()
        }
    var grpcServiceModePort: Int
        get() = preferences.getInt(SettingsKey.GRPC_PORT, 17178)!!
        set(value) = preferences.edit().putInt(SettingsKey.GRPC_PORT, value).apply()

    var startCoreAfterStartingService: Boolean
        get() = preferences.getBoolean(SettingsKey.START_CORE_ON_STARTING_SERVICE, false)
        set(value) = preferences.edit().putBoolean(SettingsKey.START_CORE_ON_STARTING_SERVICE, value).apply()


}
