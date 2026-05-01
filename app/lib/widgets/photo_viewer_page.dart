import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/utils/l10n_extensions.dart';

class PhotoViewerPage extends StatefulWidget {
  final List<ConversationPhoto> photos;
  final int initialIndex;

  const PhotoViewerPage({super.key, required this.photos, required this.initialIndex});

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  late int currentIndex;
  late final PageController pageController;

  @override
  void initState() {
    super.initState();
    currentIndex = _clampedIndex(widget.initialIndex);
    pageController = PageController(initialPage: currentIndex);
  }

  @override
  void didUpdateWidget(covariant PhotoViewerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextIndex = _clampedIndex(currentIndex);
    if (nextIndex != currentIndex) {
      currentIndex = nextIndex;
      if (widget.photos.isNotEmpty && pageController.hasClients) {
        pageController.jumpToPage(currentIndex);
      }
    }
  }

  @override
  void dispose() {
    pageController.dispose();
    super.dispose();
  }

  int _clampedIndex(int index) {
    if (widget.photos.isEmpty) return 0;
    return index.clamp(0, widget.photos.length - 1);
  }

  void onPageChanged(int index) {
    setState(() {
      currentIndex = _clampedIndex(index);
    });
  }

  PhotoViewGalleryPageOptions _buildPageOptions(ConversationPhoto photo, int index) {
    try {
      final imageBytes = base64Decode(photo.base64);
      return PhotoViewGalleryPageOptions(
        imageProvider: MemoryImage(imageBytes),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 4,
        heroAttributes: PhotoViewHeroAttributes(tag: photo.id),
        errorBuilder: (context, error, stackTrace) => _buildBrokenImage(),
      );
    } on FormatException {
      return PhotoViewGalleryPageOptions.customChild(
        child: _buildBrokenImage(),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 4,
        heroAttributes: PhotoViewHeroAttributes(tag: photo.id),
      );
    }
  }

  Widget _buildBrokenImage() {
    return const Center(
      child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.photos.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: const SafeArea(child: SizedBox.shrink()),
      );
    }

    final currentPhoto = widget.photos[currentIndex];
    final hasDescription = currentPhoto.description != null && currentPhoto.description!.isNotEmpty;
    final isProcessing = currentPhoto.description == null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PhotoViewGallery.builder(
                itemCount: widget.photos.length,
                pageController: pageController,
                onPageChanged: onPageChanged,
                builder: (context, index) {
                  final photo = widget.photos[index];
                  return _buildPageOptions(photo, index);
                },
                scrollPhysics: const BouncingScrollPhysics(),
                backgroundDecoration: const BoxDecoration(color: Colors.black),
              ),
            ),
            if (currentPhoto.discarded)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
                child: Text(
                  context.l10n.photoDiscardedMessage,
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              )
            else if (isProcessing)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      context.l10n.analyzing,
                      style: const TextStyle(color: Colors.white70, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else if (hasDescription)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
                child: Text(
                  currentPhoto.description!,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
