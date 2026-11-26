import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:client_shell/client_shell.dart';

import 'client_application.dart';
import 'client_preview_frame.dart';
import 'client_ui_validation_session.dart';

/// Observes the real unchanged App subtree after rendered frames. No business callbacks.
final class ClientUiFrameObserver extends StatefulWidget {
  const ClientUiFrameObserver({
    super.key,
    required this.session,
    required this.child,
  });
  final ClientUiValidationSession session;
  final Widget child;
  @override
  State<ClientUiFrameObserver> createState() => _ClientUiFrameObserverState();
}

final class _ClientUiFrameObserverState extends State<ClientUiFrameObserver> {
  var _frames = 0;
  bool _pending = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(_observe);
  }

  void _observe(Duration timestamp) {
    if (!mounted) return;
    _frames++;
    try {
      Element? realOwner, preview, band;
      var shell = false, loading = false, nav = false;
      void visit(Element e) {
        if (!e.mounted) return;
        final w = e.widget;
        if (w is ShiyuLocalClient) realOwner = e;
        if (w is ClientPreviewFrame) preview = e;
        if (w is ShiyuClientShell) shell = true;
        if (w is CircularProgressIndicator || w is LinearProgressIndicator) {
          loading = true;
        }
        if (w is NavigationBar && w.destinations.length == 5) nav = true;
        if (w is Material && w.color == ShiyuClientTokens.hint) band ??= e;
        e.visitChildElements(visit);
      }

      (context as Element).visitChildElements(visit);
      final object = band?.findRenderObject();
      if (realOwner != null &&
          preview != null &&
          shell &&
          nav &&
          object is RenderBox &&
          object.attached &&
          object.hasSize &&
          !_pending) {
        final view = View.of(context), dpr = view.devicePixelRatio;
        final offset = object.localToGlobal(Offset.zero);
        _pending = true;
        widget.session
            .frame(
              {
                'frameCount': _frames,
                'viewportWidth': view.physicalSize.width.round(),
                'viewportHeight': view.physicalSize.height.round(),
                'dprMilli': (dpr * 1000).round(),
                'bandLeft': (offset.dx * dpr).round(),
                'bandTop': (offset.dy * dpr).round(),
                'bandWidth': (object.size.width * dpr).round(),
                'bandHeight': (object.size.height * dpr).round(),
              },
              shellMounted: true,
              loading: loading,
            )
            .catchError((Object _) {
              widget.session.fail();
            })
            .whenComplete(() => _pending = false)
            .ignore();
      }
    } catch (_) {
      widget.session.fail();
    }
    WidgetsBinding.instance.addPostFrameCallback(
      _observe,
    ); // No scheduleFrame/forced image repair.
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
