package com.mr.flutter.plugin.filepicker;

import android.content.ContentResolver;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.net.Uri;

import androidx.annotation.NonNull;

import java.io.IOException;
import java.io.InputStream;

/**
 * Bounded two-pass decoder used by file_picker image compression.
 *
 * <p>This is a local backport of the upstream file_picker fix for the Google
 * Play oversized BitmapFactory warning. The source bounds are read without an
 * allocation and the actual decode is sampled to a power-of-two maximum side.
 */
public final class SampledBitmapDecoder {
    public static final int DEFAULT_MAX_DIMENSION = 4096;
    private static final int MAX_SOURCE_DIMENSION = 100_000;
    private static final long MAX_SOURCE_PIXELS = 1_000_000_000L;

    private SampledBitmapDecoder() {
    }

    @NonNull
    public static Bitmap decode(
            @NonNull Context context,
            @NonNull Uri uri,
            int maxDimension
    ) throws IOException {
        if (maxDimension <= 0) {
            throw new IllegalArgumentException("maxDimension must be positive");
        }

        final ContentResolver resolver = context.getContentResolver();
        final BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        try (InputStream stream = openRequired(resolver, uri)) {
            BitmapFactory.decodeStream(stream, null, bounds);
        }

        validateBounds(bounds.outWidth, bounds.outHeight);

        final BitmapFactory.Options decodeOptions = new BitmapFactory.Options();
        decodeOptions.inSampleSize = calculateInSampleSize(
                bounds.outWidth,
                bounds.outHeight,
                maxDimension,
                maxDimension
        );

        final Bitmap decoded;
        try (InputStream stream = openRequired(resolver, uri)) {
            decoded = BitmapFactory.decodeStream(stream, null, decodeOptions);
        }
        if (decoded == null) {
            throw new IOException("BitmapFactory could not decode the selected image");
        }
        return decoded;
    }

    public static int calculateInSampleSize(
            int width,
            int height,
            int requestedWidth,
            int requestedHeight
    ) {
        if (width <= 0 || height <= 0 || requestedWidth <= 0 || requestedHeight <= 0) {
            throw new IllegalArgumentException("Image and target dimensions must be positive");
        }

        int sampleSize = 1;
        while (ceilDiv(width, sampleSize) > requestedWidth
                || ceilDiv(height, sampleSize) > requestedHeight) {
            if (sampleSize > Integer.MAX_VALUE / 2) {
                return Integer.MAX_VALUE;
            }
            sampleSize *= 2;
        }
        return sampleSize;
    }

    private static int ceilDiv(int value, int divisor) {
        return (int) (((long) value + divisor - 1L) / divisor);
    }

    private static void validateBounds(int width, int height) throws IOException {
        if (width <= 0 || height <= 0) {
            throw new IOException("Selected image is empty, corrupt, or unsupported");
        }
        if (width > MAX_SOURCE_DIMENSION || height > MAX_SOURCE_DIMENSION) {
            throw new IOException("Selected image dimensions exceed the safe source limit");
        }
        if ((long) width * (long) height > MAX_SOURCE_PIXELS) {
            throw new IOException("Selected image pixel count exceeds the safe source limit");
        }
    }

    @NonNull
    private static InputStream openRequired(ContentResolver resolver, Uri uri) throws IOException {
        final InputStream stream = resolver.openInputStream(uri);
        if (stream == null) {
            throw new IOException("Content resolver returned no stream for the selected image");
        }
        return stream;
    }
}
