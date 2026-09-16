import 'dart:typed_data';

class HomeTip {
  const HomeTip({
    required this.id,
    required this.revision,
    required this.title,
    required this.imageUrl,
    required this.imageSha256,
    required this.targetUrl,
    required this.aspectRatio,
    this.expiresAt,
  });

  final String id;
  final String revision;
  final String title;
  final Uri imageUrl;
  final String imageSha256;
  final Uri targetUrl;
  final double aspectRatio;
  final DateTime? expiresAt;
  String get dismissalKey => '$id:$revision';
  bool get expired => expiresAt != null && !expiresAt!.isAfter(DateTime.now().toUtc());

  static HomeTip? parse(dynamic envelope, Uri origin) {
    if (envelope is! Map || envelope['ok'] != true) return null;
    final data = envelope['data'];
    if (data is! Map || data['schema_version'] != 1) return null;
    final tip = data['tip'];
    if (tip is! Map || tip['type'] != 'image_link') return null;
    final id = tip['id'];
    final revision = tip['revision'];
    final title = tip['title'];
    final digest = tip['image_sha256'];
    final ratio = tip['aspect_ratio'];
    if (id is! String ||
        !RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(id) ||
        revision is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(revision) ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        title is! String ||
        title.isEmpty ||
        title.length > 160 ||
        ratio is! num ||
        !ratio.isFinite ||
        ratio < 2 ||
        ratio > 6) {
      return null;
    }
    final image = Uri.tryParse(tip['image_url']?.toString() ?? '');
    final target = Uri.tryParse(tip['target_url']?.toString() ?? '');
    if (image == null || target == null) return null;
    final resolvedImage = origin.resolveUri(image);
    // First-party media only. The bearer is never sent to image or destination URLs.
    if (resolvedImage.scheme != 'https' ||
        resolvedImage.origin != origin.origin ||
        resolvedImage.userInfo.isNotEmpty ||
        !RegExp(r'^/tips/v1/assets/[a-f0-9]{64}\.(png|jpg|jpeg|webp)$').hasMatch(resolvedImage.path) ||
        target.scheme != 'https' ||
        target.host.isEmpty ||
        target.userInfo.isNotEmpty) {
      return null;
    }
    final expires = tip['expires_at'] == null ? null : DateTime.tryParse(tip['expires_at'].toString());
    if (tip['expires_at'] != null && expires == null) return null;
    return HomeTip(
      id: id,
      revision: revision,
      title: title,
      imageUrl: resolvedImage,
      imageSha256: digest,
      targetUrl: target,
      aspectRatio: ratio.toDouble(),
      expiresAt: expires,
    );
  }
}

class HomeTipContent {
  const HomeTipContent(this.tip, this.bytes);
  final HomeTip tip;
  final Uint8List bytes;
}
