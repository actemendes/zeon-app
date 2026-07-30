package test.com.zeon.zeon.bg;

import android.app.Activity;
import android.net.ConnectivityManager;
import android.net.http.HttpEngine;
import android.net.http.HttpException;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.http.NetworkException;
import android.net.http.UrlRequest;
import android.net.http.UrlResponseInfo;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;
import android.view.WindowManager;

import java.net.InetAddress;
import java.nio.ByteBuffer;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Validation-only HTTP/3 probe; never packaged in ZEON production artifacts. */
public final class Http3ValidationActivity extends Activity {
    private HttpEngine engine;
    private ExecutorService executor;
    private long bytesRead;
    private long startedAt;
    private String run;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setShowWhenLocked(true);
        setTurnScreenOn(true);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        run = getIntent().getStringExtra("run");
        if (run == null || !run.matches("[A-Za-z0-9_.:+-]{1,96}")) {
            run = "http3";
        }
        startedAt = SystemClock.elapsedRealtime();
        executor = Executors.newSingleThreadExecutor();
        executor.execute(() -> {
            try {
                InetAddress[] addresses = InetAddress.getAllByName("cloudflare.com");
                Log.i("ZEON_HTTP3", prefix("dns_success")
                        + " addresses=" + addresses.length + " " + networkSummary());
                engine = new HttpEngine.Builder(this)
                        .setEnableHttp2(true)
                        .setEnableQuic(true)
                        .addQuicHint("cloudflare.com", 443, 443)
                        .build();
                engine.newUrlRequestBuilder(
                        "https://cloudflare.com/cdn-cgi/trace",
                        executor,
                        callback
                ).build().start();
            } catch (Throwable error) {
                Log.e("ZEON_HTTP3", prefix("dns_failure")
                        + " type=" + error.getClass().getSimpleName()
                        + " reason=" + safe(error.getMessage()) + " " + networkSummary());
                closeProbe();
            }
        });
    }

    private final UrlRequest.Callback callback = new UrlRequest.Callback() {
        @Override
        public void onRedirectReceived(UrlRequest request, UrlResponseInfo info, String newLocationUrl) {
            request.followRedirect();
        }

        @Override
        public void onResponseStarted(UrlRequest request, UrlResponseInfo info) {
            Log.i("ZEON_HTTP3", prefix("response_started")
                    + " protocol=" + info.getNegotiatedProtocol()
                    + " status=" + info.getHttpStatusCode() + " " + networkSummary());
            request.read(ByteBuffer.allocateDirect(32 * 1024));
        }

        @Override
        public void onReadCompleted(UrlRequest request, UrlResponseInfo info, ByteBuffer byteBuffer) {
            bytesRead += byteBuffer.position();
            byteBuffer.clear();
            request.read(byteBuffer);
        }

        @Override
        public void onSucceeded(UrlRequest request, UrlResponseInfo info) {
            Log.i("ZEON_HTTP3", prefix("success") + " protocol=" + info.getNegotiatedProtocol()
                    + " status=" + info.getHttpStatusCode() + " body_bytes=" + bytesRead
                    + " network_bytes=" + info.getReceivedByteCount() + " " + networkSummary());
            closeProbe();
        }

        @Override
        public void onFailed(UrlRequest request, UrlResponseInfo info, HttpException error) {
            String detail = "";
            if (error instanceof NetworkException) {
                NetworkException networkError = (NetworkException) error;
                detail = " error_code=" + networkError.getErrorCode()
                        + " error_name=" + errorName(networkError.getErrorCode())
                        + " retryable=" + networkError.isImmediatelyRetryable();
            }
            Log.e("ZEON_HTTP3", prefix("failure") + " type=" + error.getClass().getSimpleName()
                    + detail + " reason=" + safe(error.getMessage()) + " " + networkSummary());
            closeProbe();
        }

        @Override
        public void onCanceled(UrlRequest request, UrlResponseInfo info) {
            Log.w("ZEON_HTTP3", prefix("canceled") + " " + networkSummary());
            closeProbe();
        }
    };

    private void closeProbe() {
        new Thread(() -> {
            try {
                if (engine != null) {
                    engine.shutdown();
                }
            } finally {
                executor.shutdown();
                runOnUiThread(this::finish);
            }
        }).start();
    }

    private String prefix(String event) {
        return "run=" + run + " event=" + event
                + " monotonic_ms=" + SystemClock.elapsedRealtime()
                + " elapsed_ms=" + (SystemClock.elapsedRealtime() - startedAt);
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

    private static String safe(String value) {
        if (value == null || value.isBlank()) {
            return "none";
        }
        String sanitized = value.replaceAll("[^A-Za-z0-9_.:+-]", "_");
        return sanitized.substring(0, Math.min(sanitized.length(), 160));
    }

    private static String errorName(int code) {
        switch (code) {
            case NetworkException.ERROR_HOSTNAME_NOT_RESOLVED:
                return "HOSTNAME_NOT_RESOLVED";
            case NetworkException.ERROR_INTERNET_DISCONNECTED:
                return "INTERNET_DISCONNECTED";
            case NetworkException.ERROR_NETWORK_CHANGED:
                return "NETWORK_CHANGED";
            case NetworkException.ERROR_TIMED_OUT:
                return "TIMED_OUT";
            case NetworkException.ERROR_CONNECTION_CLOSED:
                return "CONNECTION_CLOSED";
            case NetworkException.ERROR_CONNECTION_TIMED_OUT:
                return "CONNECTION_TIMED_OUT";
            case NetworkException.ERROR_CONNECTION_REFUSED:
                return "CONNECTION_REFUSED";
            case NetworkException.ERROR_CONNECTION_RESET:
                return "CONNECTION_RESET";
            case NetworkException.ERROR_ADDRESS_UNREACHABLE:
                return "ADDRESS_UNREACHABLE";
            case NetworkException.ERROR_QUIC_PROTOCOL_FAILED:
                return "QUIC_PROTOCOL_FAILED";
            default:
                return "OTHER";
        }
    }
}
