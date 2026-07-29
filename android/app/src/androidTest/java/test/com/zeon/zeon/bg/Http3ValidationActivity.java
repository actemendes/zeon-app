package test.com.zeon.zeon.bg;

import android.app.Activity;
import android.net.http.HttpEngine;
import android.net.http.HttpException;
import android.net.http.NetworkException;
import android.net.http.UrlRequest;
import android.net.http.UrlResponseInfo;
import android.os.Bundle;
import android.util.Log;

import java.nio.ByteBuffer;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Validation-only HTTP/3 probe; never packaged in ZEON production artifacts. */
public final class Http3ValidationActivity extends Activity {
    private HttpEngine engine;
    private ExecutorService executor;
    private long bytesRead;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        executor = Executors.newSingleThreadExecutor();
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
    }

    private final UrlRequest.Callback callback = new UrlRequest.Callback() {
        @Override
        public void onRedirectReceived(UrlRequest request, UrlResponseInfo info, String newLocationUrl) {
            request.followRedirect();
        }

        @Override
        public void onResponseStarted(UrlRequest request, UrlResponseInfo info) {
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
            Log.i("ZEON_HTTP3", "result=success protocol=" + info.getNegotiatedProtocol()
                    + " status=" + info.getHttpStatusCode() + " body_bytes=" + bytesRead
                    + " network_bytes=" + info.getReceivedByteCount());
            closeProbe();
        }

        @Override
        public void onFailed(UrlRequest request, UrlResponseInfo info, HttpException error) {
            String detail = "";
            if (error instanceof NetworkException) {
                NetworkException networkError = (NetworkException) error;
                detail = " error_code=" + networkError.getErrorCode()
                        + " retryable=" + networkError.isImmediatelyRetryable();
            }
            Log.e("ZEON_HTTP3", "result=failure type=" + error.getClass().getSimpleName() + detail);
            closeProbe();
        }

        @Override
        public void onCanceled(UrlRequest request, UrlResponseInfo info) {
            Log.w("ZEON_HTTP3", "result=canceled");
            closeProbe();
        }
    };

    private void closeProbe() {
        new Thread(() -> {
            try {
                engine.shutdown();
            } finally {
                executor.shutdown();
                runOnUiThread(this::finish);
            }
        }).start();
    }
}
