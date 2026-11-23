import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../extensions/live_catalog.dart' show extensionBootProvider;
import '../i18n/i18n.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import 'app_updater.dart';

/// Bottom sheet that runs the whole update: check → "Update now" →
/// download → verify → install. Styled with the app's own card, radius,
/// gradient button and ghost button; no icons.
Future<void> showUpdateSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const UpdateSheet(),
  );
}

class UpdateSheet extends ConsumerStatefulWidget {
  const UpdateSheet({super.key});

  @override
  ConsumerState<UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends ConsumerState<UpdateSheet> {
  @override
  void initState() {
    super.initState();
    // Opening the sheet from Settings always re-checks, unless an update
    // is already known or one is in progress.
    Future<void>.microtask(() {
      if (!mounted) return;
      final s = ref.read(updateControllerProvider);
      if (!s.busy && s.phase != UpdatePhase.available) {
        ref.read(updateControllerProvider.notifier).check();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final state = ref.watch(updateControllerProvider);
    final controller = ref.read(updateControllerProvider.notifier);
    final theme = Theme.of(context);

    final content = _content(context, state, controller);

    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(AppColors.radiusXl),
          border: Border.all(color: palette.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(context, 'update.title'), style: theme.textTheme.titleLarge),
            const SizedBox(height: 12),
            Text(content.title, style: theme.textTheme.titleSmall),
            if (content.body != null) ...[
              const SizedBox(height: 6),
              Text(
                content.body!,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: palette.muted),
              ),
            ],
            if (content.showProgress) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: state.fraction,
                  minHeight: 6,
                  color: AppColors.brand,
                  backgroundColor: palette.border,
                ),
              ),
            ],
            if (content.primary != null || content.secondary != null) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  if (content.secondary != null)
                    Expanded(
                      child: GhostButton(
                        label: content.secondary!.$1,
                        height: 48,
                        onPressed: content.secondary!.$2,
                      ),
                    ),
                  if (content.primary != null && content.secondary != null)
                    const SizedBox(width: 12),
                  if (content.primary != null)
                    Expanded(
                      child: GradientButton(
                        label: content.primary!.$1,
                        height: 48,
                        onPressed: content.primary!.$2,
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  _SheetContent _content(
      BuildContext context, UpdateState s, UpdateController c) {
    String t(String key) => tr(context, key);
    void close() => Navigator.of(context).maybePop();
    final version = s.info?.version.toString() ?? '';

    switch (s.phase) {
      case UpdatePhase.idle:
      case UpdatePhase.checking:
        return _SheetContent(title: t('update.checking'), showProgress: true);
      case UpdatePhase.upToDate:
        return _SheetContent(
          title: t('update.upToDate'),
          body: trParams(context, 'update.upToDateBody',
              {'version': s.currentVersion ?? ''}),
          secondary: (t('update.close'), close),
        );
      case UpdatePhase.available:
        return _SheetContent(
          title: trParams(context, 'update.available', {'version': version}),
          body: t('update.availableBody'),
          primary: (t('update.updateNow'), () => unawaited(c.startUpdate())),
          secondary: (t('update.later'), close),
        );
      case UpdatePhase.needsPermission:
        return _SheetContent(
          title: t('update.needsPermission'),
          body: t('update.needsPermissionBody'),
          primary: (t('update.updateNow'), () => unawaited(c.startUpdate())),
          secondary: (t('update.later'), close),
        );
      case UpdatePhase.downloading:
        final f = s.fraction;
        return _SheetContent(
          title: f == null
              ? t('update.downloadingNoSize')
              : trParams(context, 'update.downloading',
                  {'percent': (f * 100).round().toString()}),
          showProgress: true,
        );
      case UpdatePhase.verifying:
        return _SheetContent(title: t('update.verifying'), showProgress: true);
      case UpdatePhase.installing:
        return _SheetContent(
          title: t('update.installing'),
          body: t('update.installingBody'),
          showProgress: true,
        );
      case UpdatePhase.error:
        final retry = s.info != null
            ? (t('update.retry'), () => unawaited(c.startUpdate()))
            : (t('update.retry'), () => unawaited(c.check()));
        return switch (s.error) {
          UpdateError.signatureMismatch => _SheetContent(
              title: t('update.errSignature'),
              body: t('update.errSignatureBody'),
              secondary: (t('update.close'), close),
            ),
          UpdateError.unsupported => _SheetContent(
              title: t('update.errUnsupported'),
              secondary: (t('update.close'), close),
            ),
          UpdateError.network => _SheetContent(
              title: t('update.errNetwork'),
              primary: retry,
              secondary: (t('update.close'), close),
            ),
          UpdateError.noRelease => _SheetContent(
              title: t('update.errNoRelease'),
              secondary: (t('update.close'), close),
            ),
          UpdateError.download => _SheetContent(
              title: t('update.errDownload'),
              body: s.detail,
              primary: retry,
              secondary: (t('update.close'), close),
            ),
          UpdateError.integrity => _SheetContent(
              title: t('update.errIntegrity'),
              primary: retry,
              secondary: (t('update.close'), close),
            ),
          _ => _SheetContent(
              title: t('update.errInstall'),
              body: s.detail,
              primary: retry,
              secondary: (t('update.close'), close),
            ),
        };
    }
  }
}

class _SheetContent {
  const _SheetContent({
    required this.title,
    this.body,
    this.showProgress = false,
    this.primary,
    this.secondary,
  });
  final String title;
  final String? body;
  final bool showProgress;
  final (String, VoidCallback)? primary;
  final (String, VoidCallback)? secondary;
}

/// Wraps the app shell: ~4 s after launch, quietly checks GitHub once per
/// run and, if a newer release exists, offers the update sheet once.
/// Does nothing (and starts no timer) off Android or in tests.
class UpdatePromptHost extends ConsumerStatefulWidget {
  const UpdatePromptHost({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<UpdatePromptHost> createState() => _UpdatePromptHostState();
}

class _UpdatePromptHostState extends ConsumerState<UpdatePromptHost> {
  Timer? _timer;
  bool _prompted = false;

  @override
  void initState() {
    super.initState();
    // Bring installed extensions up in the background (never blocks UI).
    ref.read(extensionBootProvider);
    final controller = ref.read(updateControllerProvider.notifier);
    if (controller.supported) {
      _timer = Timer(const Duration(seconds: 4), _run);
    }
  }

  Future<void> _run() async {
    await ref.read(updateControllerProvider.notifier).autoCheck();
    if (!mounted || _prompted) return;
    if (ref.read(updateControllerProvider).phase == UpdatePhase.available) {
      _prompted = true;
      await showUpdateSheet(context);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
