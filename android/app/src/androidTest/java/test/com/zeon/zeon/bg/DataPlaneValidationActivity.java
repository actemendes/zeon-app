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
import java.io.BufferedOutputStream;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.Inet4Address;
import java.net.Inet6Address;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/**
 * Validation-only data-plane probe. It is packaged only in the isolated
 * instrumentation APK and accepts scenario names rather than arbitrary URLs,
 * preventing user profiles or credentials from entering ADB evidence.
 */
public final class DataPlaneValidationActivity extends Activity {
    private static final String TAG = "ZEON_DP";
    private static final String SPEED_HOST = "speed.cloudflare.com";
    private static final int MAX_REPETITIONS = 100;
    private static final int MAX_PARALLEL = 8;
    private static final int MAX_BYTES = 50 * 1024 * 1024;

    private ExecutorService executor;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setShowWhenLocked(true);
        setTurnScreenOn(true);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        String run = safeToken(getIntent().getStringExtra("run"), "run");
        String scenario = safeToken(getIntent().getStringExtra("scenario"), "https");
        int repetitions = bounded(getIntent().getIntExtra("repetitions", 1), 1, MAX_REPETITIONS);
        int parallel = bounded(getIntent().getIntExtra("parallel", 1), 1, MAX_PARALLEL);
        int bytes = bounded(getIntent().getIntExtra("bytes", 64 * 1024), 1, MAX_BYTES);
        long settleMs = bounded(getIntent().getLongExtra("settle_ms", 0L), 0L, 10_000L);

        executor = Executors.newFixedThreadPool(parallel);
        log(run, -1, scenario, "probe_start", networkSummary());
        new Thread(() -> {
            SystemClock.sleep(settleMs);
            for (int batchStart = 0; batchStart < repetitions; batchStart += parallel) {
                int batchSize = Math.min(parallel, repetitions - batchStart);
                for (int offset = 0; offset < batchSize; offset++) {
                    int cycle = batchStart + offset + 1;
                    executor.execute(() -> execute(run, cycle, scenario, bytes));
                }
                awaitBatch(batchStart + batchSize, repetitions);
            }
            executor.shutdown();
            try {
                executor.awaitTermination(90, TimeUnit.SECONDS);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
            }
            log(run, -1, scenario, "probe_complete", networkSummary());
            runOnUiThread(this::finish);
        }, "zeon-data-plane-controller").start();
    }

    private void execute(String run, int cycle, String scenario, int bytes) {
        long started = SystemClock.elapsedRealtime();
        try {
            DnsEvidence dns = resolve(run, cycle, scenario);
            TransferEvidence transfer;
            if (scenario.startsWith("socket_")) {
                transfer = socketTransfer(run, cycle, scenario, bytes);
            } else if ("upload".equals(scenario)) {
                transfer = upload(run, cycle, scenario, bytes);
            } else {
                int requested = "https".equals(scenario) ? Math.min(bytes, 64 * 1024) : bytes;
                transfer = download(run, cycle, scenario, requested);
            }
            log(
                    run,
                    cycle,
                    scenario,
                    "success",
                    "dns_ms=" + dns.durationMs
                            + " ipv4=" + dns.ipv4
                            + " ipv6=" + dns.ipv6
                            + " connect_tls_first_byte_ms=" + transfer.firstByteMs
                            + " total_ms=" + (SystemClock.elapsedRealtime() - started)
                            + " status=" + transfer.status
                            + " bytes=" + transfer.bytes
                            + " protocol=" + transfer.protocol
                            + " family=" + transfer.family
                            + " cipher=" + safeToken(transfer.cipher, "unknown")
                            + " " + networkSummary()
            );
        } catch (Throwable error) {
            log(
                    run,
                    cycle,
                    scenario,
                    "failure",
                    "stage=" + failureStage(error)
                            + " type=" + error.getClass().getSimpleName()
                            + " reason=" + safeToken(error.getMessage(), "none")
                            + " total_ms=" + (SystemClock.elapsedRealtime() - started)
                            + " " + networkSummary()
            );
        }
    }

    private DnsEvidence resolve(String run, int cycle, String scenario) throws IOException {
        long started = SystemClock.elapsedRealtime();
        log(run, cycle, scenario, "dns_start", networkSummary());
        InetAddress[] addresses = InetAddress.getAllByName(SPEED_HOST);
        int ipv4 = 0;
        int ipv6 = 0;
        StringBuilder addressFingerprints = new StringBuilder();
        for (InetAddress address : addresses) {
            if (address.getAddress().length == 4) {
                ipv4++;
            } else {
                ipv6++;
            }
            if (addressFingerprints.length() > 0) {
                addressFingerprints.append(',');
            }
            addressFingerprints.append(shortHash(address.getAddress()));
        }
        long duration = SystemClock.elapsedRealtime() - started;
        log(
                run,
                cycle,
                scenario,
                "dns_result",
                "duration_ms=" + duration
                        + " ipv4=" + ipv4
                        + " ipv6=" + ipv6
                        + " address_fingerprints=" + addressFingerprints
        );
        return new DnsEvidence(duration, ipv4, ipv6);
    }

    private TransferEvidence download(String run, int cycle, String scenario, int bytes) throws IOException {
        URL url = new URL("https", SPEED_HOST, "/__down?bytes=" + bytes);
        HttpsURLConnection connection = open(url);
        connection.setRequestMethod("GET");
        long started = SystemClock.elapsedRealtime();
        log(run, cycle, scenario, "tcp_tls_http_start", "direction=download requested_bytes=" + bytes);
        int status = connection.getResponseCode();
        long firstByteMs = SystemClock.elapsedRealtime() - started;
        String cipher = connection.getCipherSuite();
        long transferred = 0;
        byte[] buffer = new byte[32 * 1024];
        try (BufferedInputStream input = new BufferedInputStream(connection.getInputStream())) {
            int read;
            while ((read = input.read(buffer)) >= 0) {
                transferred += read;
            }
        } finally {
            connection.disconnect();
        }
        return new TransferEvidence(status, transferred, firstByteMs, cipher, "https_url_connection", "auto");
    }

    private TransferEvidence upload(String run, int cycle, String scenario, int bytes) throws IOException {
        URL url = new URL("https", SPEED_HOST, "/__up");
        HttpsURLConnection connection = open(url);
        connection.setRequestMethod("POST");
        connection.setDoOutput(true);
        connection.setFixedLengthStreamingMode(bytes);
        connection.setRequestProperty("Content-Type", "application/octet-stream");
        long started = SystemClock.elapsedRealtime();
        log(run, cycle, scenario, "tcp_tls_http_start", "direction=upload requested_bytes=" + bytes);
        byte[] block = new byte[32 * 1024];
        int remaining = bytes;
        try (BufferedOutputStream output = new BufferedOutputStream(connection.getOutputStream())) {
            while (remaining > 0) {
                int count = Math.min(block.length, remaining);
                output.write(block, 0, count);
                remaining -= count;
            }
        }
        int status = connection.getResponseCode();
        long firstByteMs = SystemClock.elapsedRealtime() - started;
        String cipher = connection.getCipherSuite();
        long responseBytes = 0;
        byte[] response = new byte[4096];
        try (BufferedInputStream input = new BufferedInputStream(connection.getInputStream())) {
            int read;
            while ((read = input.read(response)) >= 0) {
                responseBytes += read;
            }
        } finally {
            connection.disconnect();
        }
        return new TransferEvidence(
                status,
                bytes + responseBytes,
                firstByteMs,
                cipher,
                "https_url_connection",
                "auto"
        );
    }

    private TransferEvidence socketTransfer(
            String run,
            int cycle,
            String scenario,
            int bytes
    ) throws IOException {
        boolean ipv6 = scenario.endsWith("_ipv6");
        boolean upload = scenario.contains("upload");
        InetAddress selected = null;
        for (InetAddress address : InetAddress.getAllByName(SPEED_HOST)) {
            if ((ipv6 && address instanceof Inet6Address) || (!ipv6 && address instanceof Inet4Address)) {
                selected = address;
                break;
            }
        }
        if (selected == null) {
            throw new IOException("requested_address_family_unavailable");
        }

        String family = ipv6 ? "ipv6" : "ipv4";
        long started = SystemClock.elapsedRealtime();
        log(
                run,
                cycle,
                scenario,
                "socket_connect_start",
                "family=" + family + " address_fingerprint=" + shortHash(selected.getAddress())
        );
        Socket rawSocket = new Socket();
        rawSocket.connect(new InetSocketAddress(selected, 443), 15_000);
        rawSocket.setSoTimeout(30_000);

        SSLSocketFactory factory = (SSLSocketFactory) SSLSocketFactory.getDefault();
        try (SSLSocket socket = (SSLSocket) factory.createSocket(rawSocket, SPEED_HOST, 443, true)) {
            SSLParameters parameters = socket.getSSLParameters();
            parameters.setEndpointIdentificationAlgorithm("HTTPS");
            parameters.setApplicationProtocols(new String[]{"http/1.1"});
            socket.setSSLParameters(parameters);
            socket.startHandshake();
            String protocol = socket.getApplicationProtocol();
            log(
                    run,
                    cycle,
                    scenario,
                    "tls_success",
                    "family=" + family
                            + " protocol=" + safeToken(protocol, "unknown")
                            + " cipher=" + safeToken(socket.getSession().getCipherSuite(), "unknown")
            );

            BufferedOutputStream output = new BufferedOutputStream(socket.getOutputStream());
            String path = upload ? "/__up" : "/__down?bytes=" + bytes;
            String method = upload ? "POST" : "GET";
            String headers = method + " " + path + " HTTP/1.1\r\n"
                    + "Host: " + SPEED_HOST + "\r\n"
                    + "User-Agent: ZEON-validation/2.4\r\n"
                    + "Connection: close\r\n"
                    + (upload
                    ? "Content-Type: application/octet-stream\r\nContent-Length: " + bytes + "\r\n"
                    : "")
                    + "\r\n";
            output.write(headers.getBytes(StandardCharsets.US_ASCII));
            if (upload) {
                byte[] block = new byte[32 * 1024];
                int remaining = bytes;
                while (remaining > 0) {
                    int count = Math.min(block.length, remaining);
                    output.write(block, 0, count);
                    remaining -= count;
                }
            }
            output.flush();

            BufferedInputStream input = new BufferedInputStream(socket.getInputStream());
            byte[] response = new byte[32 * 1024];
            long responseBytes = 0;
            long firstByteMs = -1;
            int status = 0;
            StringBuilder firstLine = new StringBuilder();
            boolean firstLineComplete = false;
            int read;
            while ((read = input.read(response)) >= 0) {
                if (firstByteMs < 0) {
                    firstByteMs = SystemClock.elapsedRealtime() - started;
                }
                if (!firstLineComplete) {
                    for (int index = 0; index < read; index++) {
                        char value = (char) response[index];
                        if (value == '\n') {
                            firstLineComplete = true;
                            break;
                        }
                        if (value != '\r' && firstLine.length() < 64) {
                            firstLine.append(value);
                        }
                    }
                    String[] parts = firstLine.toString().split(" ");
                    if (parts.length >= 2) {
                        try {
                            status = Integer.parseInt(parts[1]);
                        } catch (NumberFormatException ignored) {
                            status = 0;
                        }
                    }
                }
                responseBytes += read;
            }
            if (status < 200 || status >= 300) {
                throw new IOException("unexpected_http_status_" + status);
            }
            return new TransferEvidence(
                    status,
                    (upload ? bytes : 0) + responseBytes,
                    firstByteMs,
                    socket.getSession().getCipherSuite(),
                    safeToken(protocol, "unknown"),
                    family
            );
        }
    }

    private HttpsURLConnection open(URL url) throws IOException {
        HttpsURLConnection connection = (HttpsURLConnection) url.openConnection();
        connection.setConnectTimeout(15_000);
        connection.setReadTimeout(30_000);
        connection.setInstanceFollowRedirects(false);
        connection.setRequestProperty("User-Agent", "ZEON-validation/2.4");
        connection.setRequestProperty("Connection", "close");
        return connection;
    }

    private void awaitBatch(int expectedCompleted, int total) {
        while (true) {
            long completed = executor instanceof java.util.concurrent.ThreadPoolExecutor
                    ? ((java.util.concurrent.ThreadPoolExecutor) executor).getCompletedTaskCount()
                    : expectedCompleted;
            if (completed >= expectedCompleted) {
                return;
            }
            if (completed >= total) {
                return;
            }
            SystemClock.sleep(20L);
        }
    }

    private String networkSummary() {
        ConnectivityManager manager = getSystemService(ConnectivityManager.class);
        Network network = manager.getActiveNetwork();
        NetworkCapabilities capabilities = network == null ? null : manager.getNetworkCapabilities(network);
        if (network == null || capabilities == null) {
            return "network=none";
        }
        return "network_handle=" + network.getNetworkHandle()
                + " vpn=" + capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                + " wifi=" + capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                + " cellular=" + capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
                + " validated=" + capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED);
    }

    private static int bounded(int value, int min, int max) {
        return Math.max(min, Math.min(max, value));
    }

    private static long bounded(long value, long min, long max) {
        return Math.max(min, Math.min(max, value));
    }

    private static String safeToken(String value, String fallback) {
        if (value == null || value.isBlank()) {
            return fallback;
        }
        return value.replaceAll("[^A-Za-z0-9_.:+-]", "_").substring(0, Math.min(value.length(), 96));
    }

    private static String shortHash(byte[] value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(value);
            StringBuilder result = new StringBuilder();
            for (int index = 0; index < 6; index++) {
                result.append(String.format(Locale.US, "%02x", digest[index]));
            }
            return result.toString();
        } catch (Exception ignored) {
            return "hash_error";
        }
    }

    private static String failureStage(Throwable error) {
        String name = error.getClass().getSimpleName().toLowerCase(Locale.US);
        if (name.contains("unknownhost")) {
            return "dns";
        }
        if (name.contains("ssl")) {
            return "tls";
        }
        if (name.contains("timeout")) {
            return "timeout";
        }
        if (error instanceof IOException) {
            return "tcp_or_http";
        }
        return "client";
    }

    private static void log(String run, int cycle, String scenario, String event, String details) {
        Log.i(
                TAG,
                "run=" + run
                        + " cycle=" + cycle
                        + " scenario=" + scenario
                        + " event=" + event
                        + " monotonic_ms=" + SystemClock.elapsedRealtime()
                        + " " + details
        );
    }

    private static final class DnsEvidence {
        final long durationMs;
        final int ipv4;
        final int ipv6;

        DnsEvidence(long durationMs, int ipv4, int ipv6) {
            this.durationMs = durationMs;
            this.ipv4 = ipv4;
            this.ipv6 = ipv6;
        }
    }

    private static final class TransferEvidence {
        final int status;
        final long bytes;
        final long firstByteMs;
        final String cipher;
        final String protocol;
        final String family;

        TransferEvidence(
                int status,
                long bytes,
                long firstByteMs,
                String cipher,
                String protocol,
                String family
        ) {
            this.status = status;
            this.bytes = bytes;
            this.firstByteMs = firstByteMs;
            this.cipher = cipher;
            this.protocol = protocol;
            this.family = family;
        }
    }
}
