import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/pages/chat/widgets/voice_recorder_widget.dart';

void main() {
  group('AudioWavePainter', () {
    test('shouldRepaint returns false for identical levels', () {
      final painter1 = AudioWavePainter(levels: [0.5, 0.6, 0.7]);
      final painter2 = AudioWavePainter(levels: [0.5, 0.6, 0.7]);

      expect(painter1.shouldRepaint(painter2), false);
    });

    test('shouldRepaint returns true when levels length differs', () {
      final painter1 = AudioWavePainter(levels: [0.5, 0.6]);
      final painter2 = AudioWavePainter(levels: [0.5, 0.6, 0.7]);

      expect(painter1.shouldRepaint(painter2), true);
    });

    // The repaint threshold is 0.01 (see AudioWavePainter.shouldRepaint). Diffs
    // are chosen clearly on either side of it so floating point noise at the
    // exact boundary cannot flip the result.
    test('shouldRepaint returns true when level differs by clearly more than the threshold', () {
      final painter1 = AudioWavePainter(levels: [0.5, 0.6, 0.7]);
      final painter2 = AudioWavePainter(levels: [0.5, 0.62, 0.7]); // 0.02 diff

      expect(painter1.shouldRepaint(painter2), true);
    });

    test('shouldRepaint returns false when level differs by clearly less than the threshold', () {
      final painter1 = AudioWavePainter(levels: [0.5, 0.6, 0.7]);
      final painter2 = AudioWavePainter(levels: [0.5, 0.604, 0.7]); // 0.004 diff

      expect(painter1.shouldRepaint(painter2), false);
    });

    test('shouldRepaint handles negative differences correctly (uses absolute value)', () {
      final painter1 = AudioWavePainter(levels: [0.5, 0.6, 0.7]);
      final painter2 = AudioWavePainter(levels: [0.5, 0.55, 0.7]); // -0.05 diff, abs = 0.05

      expect(painter1.shouldRepaint(painter2), true);
    });

    test('shouldRepaint returns false for empty levels', () {
      final painter1 = AudioWavePainter(levels: []);
      final painter2 = AudioWavePainter(levels: []);

      expect(painter1.shouldRepaint(painter2), false);
    });

    test('paint handles empty levels without error', () {
      final painter = AudioWavePainter(levels: []);
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);

      // Should not throw divide-by-zero or any error
      expect(() => painter.paint(canvas, const Size(100, 40)), returnsNormally);
    });

    test('painter creates defensive copy of levels list', () {
      final originalLevels = [0.5, 0.6, 0.7];
      final painter = AudioWavePainter(levels: originalLevels);

      // Modify original list
      originalLevels[0] = 1.0;

      // Painter should still have original values
      expect(painter.levels[0], 0.5);
    });
  });
}
