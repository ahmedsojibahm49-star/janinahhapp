import 'dart:ui' show DisplayFeatureType;

import 'package:material_ui/material_ui.dart';

import '../utils/cutout_insets.dart';

/// Wrap the whole app (MaterialApp `builder`) so every SafeArea / AppBar
/// keeps clear of the camera cutout even when the status bar is hidden.
/// Pass-through when the device has no cutout or the bar already covers it.
Widget withCutoutSafePadding(BuildContext context, Widget? child) {
  final inner = child ?? const SizedBox.shrink();
  final mq = MediaQuery.of(context);
  final cutouts = [
    for (final f in mq.displayFeatures)
      if (f.type == DisplayFeatureType.cutout)
        CutoutRect(f.bounds.left, f.bounds.top, f.bounds.right, f.bounds.bottom),
  ];
  if (cutouts.isEmpty) return inner;

  final padding = mq.padding;
  final lifted = liftInsetsPastCutouts(
    Insets(padding.left, padding.top, padding.right, padding.bottom),
    mq.size.width,
    mq.size.height,
    cutouts,
  );
  final unchanged = lifted ==
      Insets(padding.left, padding.top, padding.right, padding.bottom);
  if (unchanged) return inner;

  final view = mq.viewPadding;
  return MediaQuery(
    data: mq.copyWith(
      padding: EdgeInsets.fromLTRB(
          lifted.left, lifted.top, lifted.right, lifted.bottom),
      viewPadding: EdgeInsets.fromLTRB(
        lifted.left > view.left ? lifted.left : view.left,
        lifted.top > view.top ? lifted.top : view.top,
        lifted.right > view.right ? lifted.right : view.right,
        lifted.bottom > view.bottom ? lifted.bottom : view.bottom,
      ),
    ),
    child: inner,
  );
}
