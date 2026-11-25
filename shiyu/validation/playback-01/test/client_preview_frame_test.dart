// The production display boundary is tested without app/native resource owners.
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:client_shell/client_shell.dart';
import 'package:shiyu_playback_probe/client_preview_frame.dart';

void main() {
  testWidgets('safe inset has an opaque light surface', (tester) async {
    const size = Size(375, 812);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final notice = ValueNotifier<String?>('短提示');
    addTearDown(notice.dispose);
    const paintKey = ValueKey('safe-inset-paint');
    await tester.pumpWidget(
      MaterialApp(
        theme: ShiyuClientTokens.lightTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: size,
            padding: EdgeInsets.only(top: 24),
            viewPadding: EdgeInsets.only(top: 24),
          ),
          child: RepaintBoundary(
            key: paintKey,
            child: ClientPreviewFrame(
              notice: notice,
              child: const ColoredBox(color: Colors.white),
            ),
          ),
        ),
      ),
    );
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(paintKey),
    );
    final rgba = await tester.runAsync(() async {
      final rendered = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = (await rendered.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final offset = (rendered.width + 1) * 4;
        return bytes.buffer.asUint8List(bytes.offsetInBytes + offset, 4);
      } finally {
        rendered.dispose();
      }
    });
    expect(rgba, [255, 255, 255, 255]);
  });
  for (final size in [
    const Size(1280, 720),
    const Size(375, 812),
    const Size(720, 375),
  ]) {
    testWidgets('notice paints the available width at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final inset = size.width == 720
          ? const EdgeInsets.fromLTRB(24, 24, 24, 0)
          : size.width == 375
          ? const EdgeInsets.only(top: 24)
          : EdgeInsets.zero;
      final notice = ValueNotifier<String?>('短提示');
      addTearDown(notice.dispose);
      const bodyKey = ValueKey('test-content');
      const paintKey = ValueKey('frame-paint');
      await tester.pumpWidget(
        MaterialApp(
          theme: ShiyuClientTokens.lightTheme(),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              padding: inset,
              viewPadding: inset,
            ),
            child: RepaintBoundary(
              key: paintKey,
              child: ClientPreviewFrame(
                notice: notice,
                child: const ColoredBox(key: bodyKey, color: Colors.white),
              ),
            ),
          ),
        ),
      );
      final text = find.text('短提示');
      final banner = find
          .ancestor(of: text, matching: find.byType(Material))
          .first;
      final bannerRect = tester.getRect(banner);
      expect(bannerRect.left, closeTo(inset.left, 0.01));
      expect(bannerRect.right, closeTo(size.width - inset.right, 0.01));
      expect(tester.getRect(text).top, greaterThanOrEqualTo(inset.top));
      final bodyRect = tester.getRect(find.byKey(bodyKey));
      expect(bodyRect.top, closeTo(bannerRect.bottom, 0.01));
      expect(bodyRect.bottom, closeTo(size.height, 0.01));
      expect(tester.takeException(), isNull);

      notice.value = null;
      await tester.pump();
      expect(find.text('本机预览 · 仅此设备保存，尚未接入翻译、配音和发音评分'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('large notice wraps above content without overlap', (
    tester,
  ) async {
    const size = Size(375, 812);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final notice = ValueNotifier<String?>(null);
    addTearDown(notice.dispose);
    const bodyKey = ValueKey('large-text-content');
    await tester.pumpWidget(
      MaterialApp(
        theme: ShiyuClientTokens.lightTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: size,
            padding: EdgeInsets.only(top: 24),
            viewPadding: EdgeInsets.only(top: 24),
            textScaler: TextScaler.linear(2),
            disableAnimations: true,
          ),
          child: ClientPreviewFrame(
            notice: notice,
            child: const ColoredBox(key: bodyKey, color: Colors.white),
          ),
        ),
      ),
    );
    final text = find.text('本机预览 · 仅此设备保存，尚未接入翻译、配音和发音评分');
    final banner = find
        .ancestor(of: text, matching: find.byType(Material))
        .first;
    final bannerRect = tester.getRect(banner);
    final textRect = tester.getRect(text);
    final bodyRect = tester.getRect(find.byKey(bodyKey));
    expect(bannerRect.left, closeTo(0, 0.01));
    expect(bannerRect.right, closeTo(size.width, 0.01));
    expect(textRect.top, greaterThanOrEqualTo(24));
    expect(textRect.bottom, lessThanOrEqualTo(bannerRect.bottom));
    expect(bodyRect.top, closeTo(bannerRect.bottom, 0.01));
    expect(bodyRect.height, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}
