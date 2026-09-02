package test.com.zeon.zeon.bg;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.IBinder;
import android.os.SystemClock;
import android.util.Log;

import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URL;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SNIHostName;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/**
 * Validation-only traffic observer running in the separate androidTest UID.
 *
 * It is a service so ZEON remains visible for screen recording.  Inputs cannot
 * supply destinations: all targets are fixed here and logs use allowlisted IDs.
 */
public final class VerificationTrafficService extends Service {
    private static final String TAG = "ZEON_VERIFY";
    private static final String CHANNEL = "zeon_validation_traffic";
    private static final int NOTIFICATION_ID = 7601;
    private static final int CONNECT_TIMEOUT_MS = 5_000;
    private static final int READ_TIMEOUT_MS = 8_000;
    private static final Map<String, String> PROBE_TARGETS = new LinkedHashMap<>();
    private static final Map<String, String> USER_TRAFFIC_TARGETS = new LinkedHashMap<>();

    static {
        PROBE_TARGETS.put("zeon_204", "https://zeon-vps.link/generate_204");
        PROBE_TARGETS.put("gstatic_204", "https://www.gstatic.com/generate_204");
        USER_TRAFFIC_TARGETS.put("cloudflare_speed", "https://speed.cloudflare.com/__down?bytes=4096");
        USER_TRAFFIC_TARGETS.put("apple_captive", "https://captive.apple.com/hotspot-detect.html");
    }

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager notifications = getSystemService(NotificationManager.class);
        if (notifications != null) {
            notifications.createNotificationChannel(new NotificationChannel(
                    CHANNEL,
                    "ZEON validation traffic",
                    NotificationManager.IMPORTANCE_MIN
            ));
        }
        Notification notification = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("ZEON validation")
                .setContentText("Observing VPN traffic")
                .setOngoing(true)
                .build();
        startForeground(NOTIFICATION_ID, notification);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        final String run = safe(intent == null ? null : intent.getStringExtra("run"));
        Thread controller = new Thread(() -> execute(run, startId), "zeon-verification-controller");
        controller.start();
        return START_NOT_STICKY;
    }

    private void execute(String run, int startId) {
        ConnectivityManager manager = getSystemService(ConnectivityManager.class);
        Network vpn = null;
        long networkDeadline = SystemClock.elapsedRealtime() + 20_000;
        while (vpn == null && SystemClock.elapsedRealtime() < networkDeadline) {
            vpn = findVpnNetwork(manager);
            if (vpn == null) SystemClock.sleep(40);
        }
        Network active = manager == null ? null : manager.getActiveNetwork();
        String evidence = networkEvidence(manager, vpn, active);
        log(run, "matrix", "start", evidence);
        if (vpn == null) {
            log(run, "matrix", "complete", "reason=vpn_network_missing " + evidence);
            stopSelf(startId);
            return;
        }
        final Network selectedVpn = vpn;

        ExecutorService executor = Executors.newFixedThreadPool(
                PROBE_TARGETS.size() + USER_TRAFFIC_TARGETS.size()
        );
        for (Map.Entry<String, String> target : PROBE_TARGETS.entrySet()) {
            executor.execute(() -> probeStages(run, target.getKey(), target.getValue(), selectedVpn, evidence));
        }
        for (Map.Entry<String, String> target : USER_TRAFFIC_TARGETS.entrySet()) {
            executor.execute(() -> probeHttp(run, target.getKey(), target.getValue(), selectedVpn, evidence, "real_http"));
        }
        executor.shutdown();
        try {
            executor.awaitTermination(35, TimeUnit.SECONDS);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        }
        log(run, "matrix", "complete", evidence);
        stopSelf(startId);
    }

    private static Network findVpnNetwork(ConnectivityManager manager) {
        if (manager == null) return null;
        for (Network network : manager.getAllNetworks()) {
            NetworkCapabilities capabilities = manager.getNetworkCapabilities(network);
            if (capabilities != null && capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                return network;
            }
        }
        return null;
    }

    private static void probeStages(String run, String id, String endpoint, Network network, String evidence) {
        URL url;
        try {
            url = new URL(endpoint);
        } catch (Throwable error) {
            logFailure(run, id, "url", error, 0, evidence);
            return;
        }

        InetAddress[] addresses;
        long started = SystemClock.elapsedRealtime();
        try {
            addresses = network.getAllByName(url.getHost());
            int ipv4 = 0;
            int ipv6 = 0;
            for (InetAddress address : addresses) {
                if (address instanceof Inet4Address) ipv4++;
                if (address instanceof Inet6Address) ipv6++;
            }
            log(
                    run,
                    id,
                    "dns_pass",
                    "ipv4=" + ipv4 + " ipv6=" + ipv6
                            + " latency_ms=" + elapsed(started) + " " + evidence
            );
        } catch (Throwable error) {
            logFailure(run, id, "dns_fail", error, elapsed(started), evidence);
            return;
        }

        for (String family : new String[]{"ipv4", "ipv6"}) {
            InetAddress address = firstOfFamily(addresses, family);
            if (address == null) {
                log(run, id, "tcp_skip", "family=" + family + " reason=no_address " + evidence);
                continue;
            }
            probeTcp(run, id, family, address, url.getPort() > 0 ? url.getPort() : 443, network, evidence);
            probeTls(run, id, family, address, url.getHost(), url.getPort() > 0 ? url.getPort() : 443, network, evidence);
        }
        probeHttp(run, id, endpoint, network, evidence, "http");
    }

    private static void probeTcp(
            String run,
            String id,
            String family,
            InetAddress address,
            int port,
            Network network,
            String evidence
    ) {
        long started = SystemClock.elapsedRealtime();
        try (Socket socket = network.getSocketFactory().createSocket()) {
            socket.connect(new InetSocketAddress(address, port), CONNECT_TIMEOUT_MS);
            log(run, id, "tcp_pass", "family=" + family + " latency_ms=" + elapsed(started) + " " + evidence);
        } catch (Throwable error) {
            logFailure(run, id, "tcp_fail", error, elapsed(started), "family=" + family + " " + evidence);
        }
    }

    private static void probeTls(
            String run,
            String id,
            String family,
            InetAddress address,
            String host,
            int port,
            Network network,
            String evidence
    ) {
        long started = SystemClock.elapsedRealtime();
        try (Socket transport = network.getSocketFactory().createSocket()) {
            transport.connect(new InetSocketAddress(address, port), CONNECT_TIMEOUT_MS);
            transport.setSoTimeout(READ_TIMEOUT_MS);
            SSLSocketFactory factory = (SSLSocketFactory) SSLSocketFactory.getDefault();
            try (SSLSocket tls = (SSLSocket) factory.createSocket(transport, host, port, true)) {
                SSLParameters parameters = tls.getSSLParameters();
                parameters.setServerNames(java.util.Collections.singletonList(new SNIHostName(host)));
                tls.setSSLParameters(parameters);
                tls.startHandshake();
                log(
                        run,
                        id,
                        "tls_pass",
                        "family=" + family + " protocol=" + safe(tls.getSession().getProtocol())
                                + " latency_ms=" + elapsed(started) + " " + evidence
                );
            }
        } catch (Throwable error) {
            logFailure(run, id, "tls_fail", error, elapsed(started), "family=" + family + " " + evidence);
        }
    }

    private static void probeHttp(
            String run,
            String id,
            String endpoint,
            Network network,
            String evidence,
            String eventPrefix
    ) {
        long started = SystemClock.elapsedRealtime();
        HttpsURLConnection connection = null;
        try {
            connection = (HttpsURLConnection) network.openConnection(new URL(endpoint));
            connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
            connection.setReadTimeout(READ_TIMEOUT_MS);
            connection.setInstanceFollowRedirects(false);
            connection.setRequestProperty("User-Agent", "ZEON-verification-traffic/1");
            connection.setRequestProperty("Connection", "close");
            int status = connection.getResponseCode();
            log(
                    run,
                    id,
                    eventPrefix + "_pass",
                    "status=" + status + " latency_ms=" + elapsed(started) + " " + evidence
            );
        } catch (Throwable error) {
            logFailure(run, id, eventPrefix + "_fail", error, elapsed(started), evidence);
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    private static InetAddress firstOfFamily(InetAddress[] addresses, String family) {
        for (InetAddress address : addresses) {
            if ("ipv4".equals(family) && address instanceof Inet4Address) return address;
            if ("ipv6".equals(family) && address instanceof Inet6Address) return address;
        }
        return null;
    }

    private static String networkEvidence(ConnectivityManager manager, Network vpn, Network active) {
        NetworkCapabilities capabilities = manager == null || vpn == null
                ? null
                : manager.getNetworkCapabilities(vpn);
        LinkProperties links = manager == null || vpn == null ? null : manager.getLinkProperties(vpn);
        return "network_handle=" + (vpn == null ? 0 : vpn.getNetworkHandle())
                + " active_handle=" + (active == null ? 0 : active.getNetworkHandle())
                + " active_is_vpn=" + (vpn != null && vpn.equals(active))
                + " vpn=" + (capabilities != null
                && capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN))
                + " validated=" + (capabilities != null
                && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED))
                + " interface=" + safe(links == null ? null : links.getInterfaceName())
                + " dns_servers=" + (links == null ? 0 : links.getDnsServers().size());
    }

    private static void logFailure(
            String run,
            String id,
            String event,
            Throwable error,
            long latencyMs,
            String evidence
    ) {
        log(
                run,
                id,
                event,
                "type=" + safe(error.getClass().getSimpleName())
                        + " reason=" + safe(error.getMessage())
                        + " latency_ms=" + latencyMs + " " + evidence
        );
    }

    private static long elapsed(long started) {
        return SystemClock.elapsedRealtime() - started;
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
        if (value == null || value.trim().isEmpty()) return "none";
        String clean = value.replaceAll("[^A-Za-z0-9._:/=,+() -]", "_");
        return clean.substring(0, Math.min(clean.length(), 160));
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
