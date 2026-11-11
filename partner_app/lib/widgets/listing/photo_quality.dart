// Rejects blurry or very small venue photos before upload (Partner BRD §3 step 5).
//
// Size: at least 800 × 600 (either orientation). Blur: variance of the Laplacian of a downscaled grayscale copy —
// sharp photos have strong edges (high variance), blurred / out-of-focus ones don't.

import 'dart:typed_data';

import 'package:image/image.dart' as img;

const minPhotoLongSide = 800;
const minPhotoShortSide = 600;

/// Below this Laplacian variance (0–255 grayscale, ≤ 512 px long side) a photo is treated as blurry.
const blurThreshold = 30.0;

class PhotoCheck {
  const PhotoCheck({required this.ok, this.width = 0, this.height = 0, this.sharpness = 0, this.message});

  final bool ok;
  final int width;
  final int height;

  /// Laplacian variance (higher = sharper).
  final double sharpness;

  /// Friendly reason when [ok] is false.
  final String? message;
}

/// Decodes [bytes] and checks size + sharpness. Pure and synchronous — run it with `compute` for big photos.
PhotoCheck checkPhoto(Uint8List bytes) {
  final image = img.decodeImage(bytes);
  if (image == null) {
    return const PhotoCheck(ok: false, message: 'We couldn\'t read this photo. Try a JPG or PNG.');
  }
  final w = image.width, h = image.height;
  final long = w > h ? w : h, short = w > h ? h : w;
  if (long < minPhotoLongSide || short < minPhotoShortSide) {
    return PhotoCheck(
      ok: false,
      width: w,
      height: h,
      message: 'This photo is too small ($w × $h). Use one at least 800 × 600 so it looks sharp on members\' phones.',
    );
  }
  final sharpness = laplacianVariance(image);
  if (sharpness < blurThreshold) {
    return PhotoCheck(
      ok: false,
      width: w,
      height: h,
      sharpness: sharpness,
      message: 'This photo looks blurry. Hold the phone steady, tap to focus and try again in good light.',
    );
  }
  return PhotoCheck(ok: true, width: w, height: h, sharpness: sharpness);
}

/// Variance of the 4-neighbour Laplacian over a grayscale copy scaled to ≤ [maxSide] px.
double laplacianVariance(img.Image source, {int maxSide = 512}) {
  var image = source;
  final long = image.width > image.height ? image.width : image.height;
  if (long > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: maxSide, interpolation: img.Interpolation.average);
  }
  final w = image.width, h = image.height;
  if (w < 3 || h < 3) return 0;
  final gray = Float64List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = image.getPixel(x, y);
      gray[y * w + x] = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
    }
  }
  // Normalise to 0–255 whatever the source bit depth.
  final scale = 255 / image.maxChannelValue;
  var sum = 0.0, sumSq = 0.0;
  var n = 0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = y * w + x;
      final lap = (gray[i - 1] + gray[i + 1] + gray[i - w] + gray[i + w] - 4 * gray[i]) * scale;
      sum += lap;
      sumSq += lap * lap;
      n++;
    }
  }
  final mean = sum / n;
  return sumSq / n - mean * mean;
}
