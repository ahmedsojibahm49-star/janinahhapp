import 'package:flutter_test/flutter_test.dart';
import 'package:streambox/utils/cutout_insets.dart';

void main() {
  const w = 1080.0, h = 2400.0;
  const none = Insets(0, 0, 0, 0);

  test('top punch-hole lifts padding.top past the camera', () {
    // centred camera, 0..84 px tall
    const camera = CutoutRect(500, 0, 580, 84);
    expect(liftInsetsPastCutouts(none, w, h, [camera]),
        const Insets(0, 84, 0, 0));
  });

  test('a visible status bar that is already taller is left alone', () {
    const camera = CutoutRect(500, 0, 580, 84);
    const bar = Insets(0, 110, 0, 0);
    expect(liftInsetsPastCutouts(bar, w, h, [camera]), bar);
  });

  test('landscape: cutout on the left edge lifts padding.left', () {
    const camera = CutoutRect(0, 1100, 84, 1180);
    expect(liftInsetsPastCutouts(none, h, w, [camera]),
        const Insets(84, 0, 0, 0));
  });

  test('landscape: cutout on the right edge lifts padding.right', () {
    const camera = CutoutRect(2316, 500, 2400, 580);
    expect(liftInsetsPastCutouts(none, h, w, [camera]),
        const Insets(0, 0, 84, 0));
  });

  test('a cutout away from every edge changes nothing', () {
    const odd = CutoutRect(300, 300, 380, 380);
    expect(liftInsetsPastCutouts(none, w, h, [odd]), none);
  });

  test('no cutouts is a no-op', () {
    expect(liftInsetsPastCutouts(none, w, h, const []), none);
  });

  test('several cutouts take the largest', () {
    const a = CutoutRect(100, 0, 160, 60);
    const b = CutoutRect(900, 0, 960, 90);
    expect(liftInsetsPastCutouts(none, w, h, [a, b]).top, 90);
  });
}
