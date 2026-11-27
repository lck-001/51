part of '../client_shell.dart';

enum _EditorActionKind { save, confirm }

/// Reveals only an already-selected editor button. It never selects focus.
class _EditorActionVisibility extends StatefulWidget {
  const _EditorActionVisibility({
    required super.key,
    required this.scopeEpoch,
    required this.inputEpoch,
    required this.viewEpoch,
    required this.isCurrent,
    required this.buildButton,
  });

  final int scopeEpoch, inputEpoch, viewEpoch;
  final bool Function() isCurrent;
  final ButtonStyleButton Function(ValueChanged<bool>) buildButton;

  @override
  State<_EditorActionVisibility> createState() =>
      _EditorActionVisibilityState();
}

class _EditorActionReveal {
  const _EditorActionReveal(
    this.node,
    this.nodeContext,
    this.scrollable,
    this.position,
    this.route,
    this.buttonKey,
    this.buttonType,
    this.scopeEpoch,
    this.inputEpoch,
    this.viewEpoch,
    this.generation,
  );

  final FocusNode node;
  final BuildContext nodeContext;
  final ScrollableState scrollable;
  final ScrollPosition position;
  final ModalRoute<dynamic> route;
  final Key? buttonKey;
  final Type buttonType;
  final int scopeEpoch, inputEpoch, viewEpoch, generation;
}

class _EditorActionVisibilityState extends State<_EditorActionVisibility> {
  bool _active = true, _cacheReady = false, _callbackScheduled = false;
  bool _routeCurrent = false;
  int _generation = 0;
  ScrollableState? _scrollable;
  ScrollPosition? _cachedPosition;
  ModalRoute<dynamic>? _route;
  ButtonStyleButton? _button;
  FocusNode? _focusedNode;
  _EditorActionReveal? _pending;

  void _cancel({bool forgetFocus = false}) {
    _generation++;
    _pending = null;
    if (forgetFocus) _focusedNode = null;
  }

  // Ancestor queries happen only here, while this element is active. Pending
  // work uses cached references and never queries a deactivated node context.
  void _readAncestors() {
    if (!_active || !mounted) return;
    final scrollable = Scrollable.maybeOf(context);
    final route = ModalRoute.of(context);
    final position = scrollable?.position;
    final current = route?.isCurrent ?? false;
    if (!identical(scrollable, _scrollable) ||
        !identical(position, _cachedPosition) ||
        !identical(route, _route) ||
        current != _routeCurrent) {
      _cancel(forgetFocus: true);
    }
    _scrollable = scrollable;
    _cachedPosition = position;
    _route = route;
    _routeCurrent = current;
    _cacheReady = true;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _readAncestors();
  }

  @override
  void didUpdateWidget(covariant _EditorActionVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.scopeEpoch != widget.scopeEpoch ||
        oldWidget.inputEpoch != widget.inputEpoch ||
        oldWidget.viewEpoch != widget.viewEpoch;
    _cancel(forgetFocus: changed);
    if (!changed) _schedule();
  }

  @override
  void deactivate() {
    _active = false;
    _cacheReady = false;
    _cancel(forgetFocus: true);
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    // Build/didChangeDependencies refresh the cache; no ancestor lookup here.
  }

  @override
  void dispose() {
    _active = false;
    _cancel(forgetFocus: true);
    super.dispose();
  }

  void _onFocusChange(bool focused) {
    if (!focused) {
      _cancel(forgetFocus: true);
      return;
    }
    if (!_active || !mounted || !_cacheReady || !widget.isCurrent()) return;
    final node = FocusManager.instance.primaryFocus;
    if (node == null || node is FocusScopeNode || !node.hasPrimaryFocus) return;
    _focusedNode = node;
    _schedule();
  }

  void _schedule() {
    if (!_active || !mounted || !_cacheReady || !widget.isCurrent()) return;
    final node = _focusedNode, button = _button;
    final scrollable = _scrollable, position = _cachedPosition, route = _route;
    if (node == null ||
        node.context == null ||
        button == null ||
        !button.enabled ||
        !node.hasPrimaryFocus ||
        !node.canRequestFocus ||
        !identical(FocusManager.instance.primaryFocus, node) ||
        scrollable == null ||
        !scrollable.mounted ||
        position == null ||
        !identical(scrollable.position, position) ||
        route == null ||
        !route.isCurrent)
      return;
    _pending = _EditorActionReveal(
      node,
      node.context!,
      scrollable,
      position,
      route,
      button.key,
      button.runtimeType,
      widget.scopeEpoch,
      widget.inputEpoch,
      widget.viewEpoch,
      _generation,
    );
    if (_callbackScheduled) return;
    _callbackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _matches(_EditorActionReveal request) {
    if (!_active || !mounted || !_cacheReady || !widget.isCurrent())
      return false;
    final button = _button;
    return request.generation == _generation &&
        request.scopeEpoch == widget.scopeEpoch &&
        request.inputEpoch == widget.inputEpoch &&
        request.viewEpoch == widget.viewEpoch &&
        button != null &&
        button.enabled &&
        button.key == request.buttonKey &&
        button.runtimeType == request.buttonType &&
        identical(_focusedNode, request.node) &&
        request.node.hasPrimaryFocus &&
        request.node.canRequestFocus &&
        request.nodeContext.mounted &&
        identical(request.node.context, request.nodeContext) &&
        identical(FocusManager.instance.primaryFocus, request.node) &&
        identical(_route, request.route) &&
        request.route.isCurrent &&
        identical(_scrollable, request.scrollable) &&
        request.scrollable.mounted &&
        identical(request.scrollable.position, request.position) &&
        request.position.hasPixels &&
        request.position.hasContentDimensions &&
        request.position.axisDirection == AxisDirection.down;
  }

  void _reveal() {
    _callbackScheduled = false;
    final request = _pending;
    _pending = null;
    if (request == null || !_matches(request)) return;
    // These contexts belong to the active helper and its active ancestor. No
    // ancestor lookup/findRenderObject is performed on the captured node.
    final target = context.findRenderObject();
    final viewport = request.scrollable.context.findRenderObject();
    if (target is! RenderBox ||
        viewport is! RenderBox ||
        !target.attached ||
        !viewport.attached ||
        !target.hasSize ||
        !viewport.hasSize)
      return;
    final box = MatrixUtils.transformRect(
      target.getTransformTo(null),
      target.paintBounds,
    );
    final view = MatrixUtils.transformRect(
      viewport.getTransformTo(null),
      viewport.paintBounds,
    );
    if (!box.isFinite ||
        !view.isFinite ||
        box.isEmpty ||
        view.isEmpty ||
        box.height > view.height ||
        box.width > view.width ||
        box.left < view.left ||
        box.right > view.right)
      return;
    if (box.top >= view.top && box.bottom <= view.bottom) return;
    final alignment = box.bottom > view.bottom ? 1.0 : 0.0;
    if (!_matches(request) || !target.attached || !viewport.attached) return;
    unawaited(
      request.position.ensureVisible(
        target,
        alignment: alignment,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        duration: Duration.zero,
      ),
    );
    // One reveal only. No await continuation, retry, focus request or requeue.
  }

  @override
  Widget build(BuildContext context) {
    if (!_cacheReady ||
        (_scrollable?.mounted == true &&
            !identical(_scrollable!.position, _cachedPosition)))
      _readAncestors();
    final button = widget.buildButton(_onFocusChange);
    final previousButton = _button;
    if (previousButton != null &&
        (previousButton.key != button.key ||
            previousButton.runtimeType != button.runtimeType))
      _cancel(forgetFocus: true);
    _button = button;
    return button;
  }
}
