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
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import javax.net.ssl.HttpsURLConnection;

/**
 * Validation-only, fixed-target matrix used to distinguish a destination
 * failure from a VPN-wide data-plane failure.  It accepts no URLs, headers or
 * profile data from the intent and logs only allowlisted target identifiers.
 */
public final class GlobalDataPlaneMatrixActivity extends Activity {
    private static final String TAG = "ZEON_MATRIX";
    private static final int MAX_RESPONSE_BYTES = 64 * 1024;
    private static final Map<String, String> TARGETS = new LinkedHashMap<>();

    static {
        TARGETS.put("zeon_204", "https://zeon-vps.link/generate_204");
        TARGETS.put("gstatic_204", "https://www.gstatic.com/generate_204");
        TARGETS.put("cloudflare_speed", "https://speed.cloudflare.com/__down?bytes=4096");
        TARGETS.put("apple_captive", "https://captive.apple.com/hotspot-detect.html");
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setShowWhenLocked(true);
        setTurnScreenOn(true);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        String run = safe(getIntent().getStringExtra("run"));
        ConnectivityManager manager = getSystemService(ConnectivityManager.class);
        Network network = manager == null ? null : manager.getActiveNetwork();
        NetworkCapabilities capabilities = manager == null || network == null
                ? null
                : manager.getNetworkCapabilities(network);
        String networkEvidence = networkEvidence(network, capabilities);
        log(run, "matrix", "start", networkEvidence);

        ExecutorService executor = Executors.newFixedThreadPool(TARGETS.size());
        CountDownLatch complete = new CountDownLatch(TARGETS.size());
        for (Map.Entry<String, String> target : TARGETS.entrySet()) {
            executor.execute(() -> {
                try {
                    probe(run, target.getKey(), target.getValue(), network, networkEvidence);
                } finally {
                    complete.countDown();
                }
            });
        }
        executor.shutdown();
        new Thread(() -> {
            try {
                complete.await(40, TimeUnit.SECONDS);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
            }
            log(run, "matrix", "complete", "remaining=" + complete.getCount() + " " + networkEvidence);
            runOnUiThread(this::finish);
        }, "zeon-global-matrix-controller").start();
    }

    private static void probe(
            String run,
            String id,
            String endpoint,
            Network network,
            String networkEvidence
    ) {
        long started = SystemClock.elapsedRealtime();
        HttpsURLConnection connection = null;
        try {
            if (network == null) {
                throw new IllegalStateException("active_network_unavailable");
            }
            URL url = new URL(endpoint);
            int ipv4 = 0;
            int ipv6 = 0;
            for (InetAddress address : network.getAllByName(url.getHost())) {
                if (address instanceof Inet4Address) {
                    ipv4++;
                } else if (address instanceof Inet6Address) {
                    ipv6++;
                }
            }
            log(run, id, "dns", "ipv4=" + ipv4 + " ipv6=" + ipv6 + " " + networkEvidence);

            connection = (HttpsURLConnection) network.openConnection(url);
            connection.setConnectTimeout(12_000);
            connection.setReadTimeout(18_000);
            connection.setInstanceFollowRedirects(false);
            connection.setRequestProperty("User-Agent", "ZEON-validation-matrix/1");
            connection.setRequestProperty("Connection", "close");
            int status = connection.getResponseCode();
            long firstByteMs = SystemClock.elapsedRealtime() - started;
            long bytes = 0;
            try (BufferedInputStream input = new BufferedInputStream(
                    status >= 400 && connection.getErrorStream() != null
                            ? connection.getErrorStream()
                            : connection.getInputStream()
            )) {
                byte[] buffer = new byte[8192];
                int read;
                while (bytes < MAX_RESPONSE_BYTES && (read = input.read(buffer)) >= 0) {
                    bytes += read;
                }
            }
            log(
                    run,
                    id,
                    "success",
                    "status=" + status
                            + " bytes=" + bytes
                            + " first_byte_ms=" + firstByteMs
                            + " total_ms=" + (SystemClock.elapsedRealtime() - started)
                            + " " + networkEvidence
            );
        } catch (Throwable error) {
            log(
                    run,
                    id,
                    "failure",
                    "type=" + safe(error.getClass().getSimpleName())
                            + " reason=" + safe(error.getMessage())
                            + " total_ms=" + (SystemClock.elapsedRealtime() - started)
                            + " " + networkEvidence
            );
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private static String networkEvidence(Network network, NetworkCapabilities capabilities) {
        return "network_handle=" + (network == null ? 0 : network.getNetworkHandle())
                + " vpn=" + (capabilities != null
                && capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN))
                + " validated=" + (capabilities != null
                && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED));
    }

    private static void log(String run, String target, String event, String details) {
        Log.i(
                TAG,
                "run=" + run
                        + " target=" + target
                        + " event=" + event
                        + " monotonic_ms=" + SystemClock.elapsedRealtime()
                        + " " + details
        );
    }

    private static String safe(String value) {
        if (value == null || value.isBlank()) {
            return "none";
        }
        String safe = value.replaceAll("[^A-Za-z0-9._:/=,+-]", "_");
        return safe.substring(0, Math.min(safe.length(), 120));
    }
}
