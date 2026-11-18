import 'dart:async';

import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quill/components/canvas/hud/canvas_zoom_indicator.dart';
import 'package:quill/data/extensions/matrix4_extensions.dart';

class CanvasHud extends HookWidget {
  const new({
    super.key,
    required this.transformationController,
    required this.resetZoom,
  });

  final TransformationController transformationController;
  final VoidCallback? resetZoom;

  @override
  Widget build(BuildContext context) {
    /// The opacity of the HUD
    final opacity = useState(0.0);

    /// A timer to set the opacity to 0 after inactivity
    final hideTimer = useRef<Timer?>(null);
    useEffect(() => hideTimer.value?.cancel, [hideTimer.value]);

    void onTransform() {
      opacity.value = 1;
      hideTimer.value?.cancel();
      hideTimer.value = Timer(
        const Duration(seconds: 5),
        () => opacity.value = 0,
      );
    }

    useOnListenableChange(transformationController, onTransform);

    return IgnorePointer(
      ignoring: opacity.value < 0.5,
      child: AnimatedOpacity(
        opacity: opacity.value,
        duration: const Duration(milliseconds: 200),
        child: Stack(
          children: [
            Positioned(
              top: 5,
              right: 5,
              child: AnimatedBuilder(
                animation: transformationController,
                builder: (context, _) => CanvasZoomIndicator(
                  scale: transformationController.value.approxScale,
                  resetZoom: resetZoom,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
