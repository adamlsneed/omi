import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/widgets/photo_viewer_page.dart';

class PhotosGridComponent extends StatelessWidget {
  final List<ConversationPhoto> photos;
  const PhotosGridComponent({super.key, required this.photos});

  static Uint8List? _decodedBytes(ConversationPhoto photo) {
    try {
      return base64Decode(photo.base64);
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: EdgeInsets.zero,
      scrollDirection: Axis.vertical,
      itemCount: photos.length,
      itemBuilder: (context, idx) {
        final photo = photos[idx];
        final isProcessing = !photo.discarded && photo.description == null;
        final imageBytes = _decodedBytes(photo);

        return GestureDetector(
          key: ValueKey(photo.id),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => PhotoViewerPage(photos: photos, initialIndex: idx),
              ),
            );
          },
          child: Hero(
            tag: photo.id,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8.0),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (imageBytes == null)
                    Container(
                      color: Colors.black26,
                      child: const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 28),
                    )
                  else
                    Image.memory(
                      imageBytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      color: photo.discarded ? const Color(0xFF35343B) : null,
                      colorBlendMode: photo.discarded ? BlendMode.saturation : null,
                      errorBuilder: (context, error, stackTrace) => Container(
                        color: Colors.black26,
                        child: const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 28),
                      ),
                    ),
                  if (photo.discarded)
                    Container(
                      color: Colors.black.withValues(alpha: 0.5),
                      child: const Icon(Icons.visibility_off_outlined, color: Colors.white70, size: 28),
                    ),
                  if (isProcessing)
                    Container(
                      color: Colors.black.withValues(alpha: 0.5),
                      child: const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.0,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        childAspectRatio: 800 / 600,
      ),
    );
  }
}
