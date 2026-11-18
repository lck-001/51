import 'package:material_ui/material_ui.dart';

/// Prevents pointer, focus/keyboard and accessibility actions after app-owned
/// retirement. The owner also synchronously unfocuses when retiring admission.
class ClientCommandBarrier extends StatelessWidget {
  const ClientCommandBarrier({
    super.key,
    required this.frozen,
    required this.child,
  });
  final bool frozen;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: frozen,
    child: ExcludeFocus(
      excluding: frozen,
      child: ExcludeSemantics(excluding: frozen, child: child),
    ),
  );
}
