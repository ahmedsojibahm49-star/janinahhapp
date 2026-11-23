/// Pure maths for the camera-cutout (notch / punch-hole) fix.
///
/// Why it exists: the app runs in Android immersive mode, which hides the
/// status bar. Flutter then reports `MediaQuery.padding.top == 0`, yet the
/// physical camera cutout is still there, so content drawn from y = 0 ends
/// up under the camera. Reading the cutout rectangles and lifting the
/// padding past them fixes every screen that uses SafeArea / AppBar,
/// without touching any of those screens.

class CutoutRect {
  const CutoutRect(this.left, this.top, this.right, this.bottom);
  final double left;
  final double top;
  final double right;
  final double bottom;
}

class Insets {
  const Insets(this.left, this.top, this.right, this.bottom);
  final double left;
  final double top;
  final double right;
  final double bottom;

  @override
  bool operator ==(Object other) =>
      other is Insets &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'Insets($left, $top, $right, $bottom)';
}

double _max(double a, double b) => a > b ? a : b;

/// Raise [base] so it clears every cutout that touches a screen edge.
/// Never lowers an inset that is already larger (e.g. a visible status
/// bar), so it is a no-op outside immersive mode.
Insets liftInsetsPastCutouts(
  Insets base,
  double screenWidth,
  double screenHeight,
  Iterable<CutoutRect> cutouts,
) {
  const eps = 1.0;
  var left = base.left;
  var top = base.top;
  var right = base.right;
  var bottom = base.bottom;
  for (final c in cutouts) {
    if (c.top <= eps) top = _max(top, c.bottom);
    if (c.left <= eps) left = _max(left, c.right);
    if (c.right >= screenWidth - eps) {
      right = _max(right, screenWidth - c.left);
    }
    if (c.bottom >= screenHeight - eps) {
      bottom = _max(bottom, screenHeight - c.top);
    }
  }
  return Insets(left, top, right, bottom);
}
