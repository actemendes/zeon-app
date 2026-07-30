package test.com.zeon.zeon.bg;

import android.app.Activity;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;
import android.view.WindowManager;

import java.io.BufferedInputStream;
import java.net.HttpURLConnection;
import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.URL;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import javax.net.ssl.HttpsURLConnection;

/**
 * Validation-only probe for public Russian service entry points.
 *
 * The exported activity accepts service identifiers, never arbitrary URLs.
 * It does not send cookies, credentials, profile data, or subscription data.
 * Log output contains the stable service identifier rather than the hostname.
 */
public final class RussianServicesValidationActivity extends Activity {
    private static final String TAG = "ZEON_RU";
    private static final int MAX_RESPONSE_BYTES = 512 * 1024;
    private static final Map<String, String> SERVICES = new LinkedHashMap<>();

    static {
        SERVICES.put("gosuslugi", "https://www.gosuslugi.ru/");
        SERVICES.put("esia_public", "https://esia.gosuslugi.ru/");
        SERVICES.put("nalog", "https://www.nalog.gov.ru/");
        SERVICES.put("mos", "https://www.mos.ru/");
        SERVICES.put("cbr", "https://www.cbr.ru/");
        SERVICES.put("sbp", "https://sbp.nspk.ru/");
        SERVICES.put("sber", "https://www.sberbank.ru/");
        SERVICES.put("tbank", "https://www.tbank.ru/");
        SERVICES.put("alfabank", "https://alfabank.ru/");
        SERVICES.put("gazprombank", "https://www.gazprombank.ru/");
        SERVICES.put("yandex", "https://yandex.ru/");
        SERVICES.put("vk", "https://vk.com/");
        SERVICES.put("mailru", "https://mail.ru/");
        SERVICES.put("ok", "https://ok.ru/");
        SERVICES.put("dzen", "https://dzen.ru/");
        SERVICES.put("ozon", "https://www.ozon.ru/");
        SERVICES.put("wildberries", "https://www.wildberries.ru/");
        SERVICES.put("avito", "https://www.avito.ru/");
        SERVICES.put("2gis", "https://2gis.ru/");
        SERVICES.put("rutube", "https://rutube.ru/");
        SERVICES.put("kinopoisk", "https://www.kinopoisk.ru/");
        SERVICES.put("rustore", "https://www.rustore.ru/");
        SERVICES.put("rzd", "https://www.rzd.ru/");
        SERVICES.put("aeroflot", "https://www.aeroflot.ru/");
        SERVICES.put("hh", "https://hh.ru/");
        SERVICES.put("ria", "https://ria.ru/");
        SERVICES.put("lenta", "https://lenta.ru/");
        SERVICES.put("megamarket", "https://megamarket.ru/");
    }

    private ExecutorService executor;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setShowWhenLocked(true);
        setTurnScreenOn(true);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        String requested = getIntent().getStringExtra("service");
        executor = Executors.newSingleThreadExecutor();
        executor.execute(() -> {
            if (requested == null || "all".equals(requested)) {
                for (Map.Entry<String, String> service : SERVICES.entrySet()) {
                    probe(service.getKey(), service.getValue());
                }
            } else if (SERVICES.containsKey(requested)) {
                probe(requested, SERVICES.get(requested));
            } else {
                log(requested == null ? "missing" : requested, "rejected", "reason=unknown_service");
            }
            executor.shutdown();
            try {
                executor.awaitTermination(5, TimeUnit.SECONDS);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
            }
            runOnUiThread(this::finish);
        });
    }

    private void probe(String id, String endpoint) {
        long started = SystemClock.elapsedRealtime();
        HttpsURLConnection connection = null;
        try {
            URL url = new URL(endpoint);
            int ipv4 = 0;
            int ipv6 = 0;
            for (InetAddress address : InetAddress.getAllByName(url.getHost())) {
                if (address instanceof Inet4Address) {
                    ipv4++;
                } else if (address instanceof Inet6Address) {
                    ipv6++;
                }
            }
            log(id, "dns", "ipv4=" + ipv4 + " ipv6=" + ipv6 + " " + networkSummary());

            connection = (HttpsURLConnection) url.openConnection();
            connection.setConnectTimeout(15_000);
            connection.setReadTimeout(20_000);
            connection.setInstanceFollowRedirects(true);
            connection.setRequestProperty("User-Agent", "ZEON-Route-Validation/1");
            connection.setRequestProperty("Accept", "text/html,application/json;q=0.9,*/*;q=0.1");

            int status = connection.getResponseCode();
            long firstByteMs = SystemClock.elapsedRealtime() - started;
            long bytes = 0;
            try (BufferedInputStream input = new BufferedInputStream(
                    status >= 400 && connection.getErrorStream() != null
                            ? connection.getErrorStream()
                            : connection.getInputStream()
            )) {
                byte[] buffer = new byte[16 * 1024];
                int read;
                while (bytes < MAX_RESPONSE_BYTES && (read = input.read(buffer)) >= 0) {
                    bytes += read;
                }
            }
            log(
                    id,
                    "result",
                    "status=" + status
                            + " bytes=" + bytes
                            + " first_byte_ms=" + firstByteMs
                            + " total_ms=" + (SystemClock.elapsedRealtime() - started)
                            + " " + networkSummary()
            );
        } catch (Throwable error) {
            log(
                    id,
                    "failure",
                    "type=" + safe(error.getClass().getSimpleName())
                            + " reason=" + safe(error.getMessage())
                            + " total_ms=" + (SystemClock.elapsedRealtime() - started)
                            + " " + networkSummary()
            );
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private String networkSummary() {
        ConnectivityManager manager = getSystemService(ConnectivityManager.class);
        Network active = manager == null ? null : manager.getActiveNetwork();
        NetworkCapabilities capabilities =
                manager == null || active == null ? null : manager.getNetworkCapabilities(active);
        return "vpn=" + (capabilities != null
                && capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN))
                + " validated=" + (capabilities != null
                && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED));
    }

    private static void log(String service, String event, String details) {
        Log.i(
                TAG,
                "service=" + safe(service)
                        + " event=" + event
                        + " monotonic_ms=" + SystemClock.elapsedRealtime()
                        + " " + details
        );
    }

    private static String safe(String value) {
        if (value == null) {
            return "none";
        }
        return value.replaceAll("[^A-Za-z0-9._:/=,+-]", "_");
    }
}
