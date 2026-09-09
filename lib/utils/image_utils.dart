import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Normalizes EXIF rotation into actual pixel data, optionally
/// resizes, and re-encodes as JPEG.
///
/// Several Android devices write photos with an EXIF orientation TAG
/// rather than physically rotating the pixel data itself — a viewer
/// that respects EXIF renders it correctly, but a plain Image.file
/// widget (what this app uses throughout) does NOT apply EXIF
/// automatically, so the photo shows up sideways. Baking the rotation
/// in once, here, means every consumer downstream always sees the
/// photo already upright.
Uint8List normalizeAndCompress(Uint8List bytes, {int? maxWidth, int quality = 75}) {
  var decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;

  decoded = img.bakeOrientation(decoded);

  if (maxWidth != null && decoded.width > maxWidth) {
    decoded = img.copyResize(decoded, width: maxWidth);
  }

  return Uint8List.fromList(img.encodeJpg(decoded, quality: quality));
}

/// Computes a Laplacian-variance sharpness score on a downsampled
/// grayscale version of the image — a standard, lightweight technique
/// for detecting motion blur without needing a full ML model. Higher
/// score = sharper. Used to pick the least-blurred frame among a few
/// candidates extracted near the same target timestamp in video mode,
/// where walking motion is the main source of blurry keyframes.
double sharpnessScore(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return 0;

  // Downsample first — sharpness comparison between candidates
  // doesn't need full resolution, and this keeps the per-frame cost
  // low even though we're now doing this 3x per stop.
  final small = img.copyResize(decoded, width: 160);
  final gray = img.grayscale(small);

  double sum = 0;
  double sumSq = 0;
  int count = 0;

  for (int y = 1; y < gray.height - 1; y++) {
    for (int x = 1; x < gray.width - 1; x++) {
      final center = gray.getPixel(x, y).r.toDouble();
      final left = gray.getPixel(x - 1, y).r.toDouble();
      final right = gray.getPixel(x + 1, y).r.toDouble();
      final top = gray.getPixel(x, y - 1).r.toDouble();
      final bottom = gray.getPixel(x, y + 1).r.toDouble();
      final laplacian = (4 * center) - left - right - top - bottom;
      sum += laplacian;
      sumSq += laplacian * laplacian;
      count++;
    }
  }

  if (count == 0) return 0;
  final mean = sum / count;
  return (sumSq / count) - (mean * mean); // variance
}