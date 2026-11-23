import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import 'package:material_ui/material_ui.dart';

import '../../extensions/core/host.dart';
import '../../extensions/core/manager.dart';
import '../../extensions/core/models.dart';
import '../../extensions/live_catalog.dart';
import '../../i18n/i18n.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import '../screen_helpers.dart';

/// Settings > Providers > Extensions: the Extension Store plus everything
/// about installed extensions (enable/disable, update, uninstall, details).
/// Repositories live one screen over (`extension_repos_screen.dart`).

enum _Filter {
  all,
  installed,
  notInstalled,
  enabled,
  disabled,
  anime,
  movies,
  tvSeries,
  other,
}

enum _Sort { name, version, installedFirst }

/// Localised message for a failed extension action.
String extensionErrorText(BuildContext context, Object error) {
  if (error is ExtensionException) {
    final base = tr(context, 'ext.err.${error.error.name}');
    return error.message.isEmpty ? base : '$base\n${error.message}';
  }
  return tr(context, 'common.errorGeneric');
}

/// Run [action]; show the failure as a snack instead of throwing.
Future<bool> runExtensionAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
    return true;
  } on ExtensionException catch (e) {
    if (context.mounted) showSnack(context, extensionErrorText(context, e));
    return false;
  } on Object {
    if (context.mounted) showSnack(context, tr(context, 'common.errorGeneric'));
    return false;
  }
}

String formatStamp(int? millis) {
  if (millis == null) return '—';
  final d = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class ExtensionsScreen extends ConsumerStatefulWidget {
  const ExtensionsScreen({super.key});

  @override
  ConsumerState<ExtensionsScreen> createState() => _ExtensionsScreenState();
}

class _ExtensionsScreenState extends ConsumerState<ExtensionsScreen> {
  _Filter _filter = _Filter.all;
  _Sort _sort = _Sort.name;
  String _query = '';
  bool _updatingAll = false;

  List<StoreItem> _apply(List<StoreItem> items) {
    final q = _query.trim().toLowerCase();
    bool matches(StoreItem i) {
      if (q.isNotEmpty) {
        final hay = '${i.entry.name} ${i.entry.description ?? ''} '
                '${i.entry.authors.join(' ')} ${i.entry.language ?? ''} '
                '${i.entry.tvTypes.join(' ')}'
            .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      final cats = i.entry.categories;
      return switch (_filter) {
        _Filter.all => true,
        _Filter.installed => i.isInstalled,
        _Filter.notInstalled => !i.isInstalled,
        _Filter.enabled => i.isInstalled && i.isEnabled,
        _Filter.disabled => i.isInstalled && !i.isEnabled,
        _Filter.anime => cats.contains(ExtensionCategory.anime),
        _Filter.movies => cats.contains(ExtensionCategory.movies),
        _Filter.tvSeries => cats.contains(ExtensionCategory.tvSeries),
        _Filter.other => cats.contains(ExtensionCategory.other),
      };
    }

    final out = items.where(matches).toList();
    switch (_sort) {
      case _Sort.name:
        break; // already name-sorted by the manager
      case _Sort.version:
        out.sort((a, b) => b.entry.version.compareTo(a.entry.version));
      case _Sort.installedFirst:
        out.sort((a, b) {
          final c = (b.isInstalled ? 1 : 0).compareTo(a.isInstalled ? 1 : 0);
          return c != 0
              ? c
              : a.entry.name.toLowerCase().compareTo(b.entry.name.toLowerCase());
        });
    }
    return out;
  }

  String _filterLabel(_Filter f) => tr(context, 'ext.filter.${f.name}');

  Future<void> _refresh() async {
    final manager = ref.read(extensionManagerProvider);
    final failed = await manager.refreshAll();
    if (!mounted) return;
    if (failed > 0) {
      showSnack(context, tr(context, 'ext.refreshSomeFailed'));
    }
  }

  Future<void> _updateAll() async {
    if (_updatingAll) return;
    setState(() => _updatingAll = true);
    final result = await ref.read(extensionManagerProvider).updateAll();
    if (!mounted) return;
    setState(() => _updatingAll = false);
    showSnack(
      context,
      trParams(context, 'ext.updateAllResult', {
        'updated': '${result.updated}',
        'failed': '${result.failed}',
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    ref.watch(extensionsRevisionProvider);
    final manager = ref.read(extensionManagerProvider);
    final all = ref.watch(extensionStoreItemsProvider);
    final shown = _apply(all);
    final updates = manager.updatesAvailable().length;
    final hostInfo = manager.hostInfo;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(tr(context, 'ext.title')),
        actions: [
          IconButton(
            tooltip: tr(context, 'ext.sort.${_sort.name}'),
            icon: const Icon(Iconsax.sort_copy),
            onPressed: () => setState(() {
              _sort = _Sort.values[(_sort.index + 1) % _Sort.values.length];
            }),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: GhostButton(
                    label: trParams(context, 'ext.repositories', {
                      'count': '${manager.repos.length}',
                    }),
                    height: 44,
                    onPressed: () =>
                        context.push('/settings/providers/extensions/repos'),
                  ),
                ),
                if (updates > 0) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: GradientButton(
                      label: trParams(context, 'ext.updateAll', {
                        'count': '$updates',
                      }),
                      height: 44,
                      loading: _updatingAll,
                      onPressed: _updateAll,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (manager.isLoaded && !hostInfo.available)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: palette.card,
                  borderRadius: BorderRadius.circular(AppColors.radiusM),
                  border: Border.all(color: palette.border),
                ),
                child: Text(
                  '${tr(context, 'ext.noRuntime')}\n'
                  '${hostInfo.unavailableReason ?? ''}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: palette.muted),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SearchField(
              hintKey: 'ext.searchHint',
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _Filter.values.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final f = _Filter.values[i];
                return ChipToggle(
                  label: _filterLabel(f),
                  selected: _filter == f,
                  onTap: () => setState(() => _filter = f),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: all.isEmpty
                ? EmptyState(
                    title: tr(context, 'ext.emptyTitle'),
                    body: tr(context, 'ext.emptyBody'),
                    icon: Iconsax.folder_open_copy,
                    actionLabel: tr(context, 'ext.addRepository'),
                    onAction: () =>
                        context.push('/settings/providers/extensions/repos'),
                  )
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: shown.isEmpty
                        ? ListView(
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(32),
                                child: Center(
                                  child: Text(
                                    tr(context, 'ext.noMatches'),
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(color: palette.muted),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : ListView.builder(
                            padding:
                                const EdgeInsets.fromLTRB(16, 4, 16, 24),
                            itemCount: shown.length,
                            itemBuilder: (context, i) =>
                                ExtensionCard(item: shown[i]),
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One extension row: icon, name, meta, state and its primary action.
class ExtensionCard extends ConsumerWidget {
  const ExtensionCard({super.key, required this.item});

  final StoreItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final manager = ref.read(extensionManagerProvider);
    final e = item.entry;
    final progress = manager.progressOf(item.internalName);
    final busy = manager.isBusy(item.internalName);

    final meta = [
      'v${e.version}',
      if (e.language != null) e.language!,
      if (e.tvTypes.isNotEmpty) e.tvTypes.take(3).join(', '),
    ].join(' · ');

    Widget trailing;
    if (progress != null) {
      trailing = SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(
            strokeWidth: 3, value: progress.fraction),
      );
    } else if (busy) {
      trailing = const SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 3),
      );
    } else if (item.isInstalled) {
      trailing = Switch(
        value: item.isEnabled,
        onChanged: (v) => runExtensionAction(
          context,
          () => manager.setEnabled(item.internalName, v),
        ),
      );
    } else if (item.canInstall) {
      trailing = SizedBox(
        width: 96,
        child: GradientButton(
          label: tr(context, 'ext.install'),
          height: 40,
          onPressed: () => runExtensionAction(
            context,
            () => manager.install(item.internalName),
          ),
        ),
      );
    } else {
      trailing = const SizedBox.shrink();
    }

    final status = _statusText(context, progress);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: palette.card,
        borderRadius: BorderRadius.circular(AppColors.radiusM),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppColors.radiusM),
          onTap: () => showExtensionDetails(context, item.internalName),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: e.iconUrl == null
                            ? ColoredBox(
                                color: palette.surface,
                                child: Center(
                                  child: Text(
                                    (e.name.isEmpty ? '?' : e.name[0].toUpperCase()),
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ),
                              )
                            : AppImage(src: e.iconUrl!, width: 48, height: 48),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleSmall),
                          const SizedBox(height: 2),
                          Text(meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: palette.muted)),
                          if (e.authors.isNotEmpty)
                            Text(e.authors.take(2).join(', '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: palette.muted)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    trailing,
                  ],
                ),
                if (e.description != null) ...[
                  const SizedBox(height: 8),
                  Text(e.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: palette.muted)),
                ],
                const SizedBox(height: 8),
                Text(
                  '${item.repo.name} · $status',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: item.hasUpdate ? AppColors.brand : palette.muted,
                  ),
                ),
                if (item.hasUpdate && !busy && progress == null) ...[
                  const SizedBox(height: 10),
                  GhostButton(
                    label: trParams(context, 'ext.updateTo', {
                      'version': '${e.version}',
                    }),
                    height: 40,
                    onPressed: () => runExtensionAction(
                      context,
                      () => manager.install(item.internalName),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _statusText(BuildContext context, InstallProgress? progress) {
    if (progress != null) {
      return switch (progress.phase) {
        InstallPhase.downloading => progress.fraction == null
            ? tr(context, 'ext.state.downloading')
            : trParams(context, 'ext.state.downloadingPct', {
                'percent': '${(progress.fraction! * 100).round()}',
              }),
        InstallPhase.verifying => tr(context, 'ext.state.verifying'),
        InstallPhase.installing => tr(context, 'ext.state.installing'),
      };
    }
    if (item.isInstalled) {
      final rec = item.installed!;
      if (item.hasUpdate) {
        return trParams(context, 'ext.state.updateAvailable', {
          'version': '${item.entry.version}',
        });
      }
      if (rec.lastError != null) return tr(context, 'ext.state.error');
      return item.isEnabled
          ? tr(context, 'ext.state.enabled')
          : tr(context, 'ext.state.disabled');
    }
    return switch (item.compatibility) {
      Compatibility.compatible => tr(context, 'ext.state.notInstalled'),
      Compatibility.unsupportedPlatform =>
        tr(context, 'ext.compat.unsupportedPlatform'),
      Compatibility.apiMismatch => tr(context, 'ext.compat.apiMismatch'),
      Compatibility.unsupportedPackage =>
        tr(context, 'ext.compat.unsupportedPackage'),
    };
  }
}

// ======================================================== details sheet

Future<void> showExtensionDetails(BuildContext context, String internalName) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ExtensionDetailsSheet(internalName: internalName),
  );
}

class ExtensionDetailsSheet extends ConsumerWidget {
  const ExtensionDetailsSheet({super.key, required this.internalName});

  final String internalName;

  Future<void> _confirmUninstall(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'ext.uninstallTitle')),
        content: Text(tr(ctx, 'ext.uninstallBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr(ctx, 'common.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr(ctx, 'ext.uninstall')),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await runExtensionAction(
      context,
      () => ref.read(extensionManagerProvider).uninstall(internalName),
    );
    if (context.mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(extensionsRevisionProvider);
    final manager = ref.read(extensionManagerProvider);
    final item = manager.storeItem(internalName);
    final rec = manager.installedRecord(internalName);
    final palette = context.palette;
    final theme = Theme.of(context);

    // Installed but no longer listed by any repository: show the record.
    final name = item?.entry.name ?? rec?.name ?? internalName;
    final description = item?.entry.description ?? rec?.description;
    final authors = item?.entry.authors ?? rec?.authors ?? const <String>[];
    final language = item?.entry.language ?? rec?.language;
    final types = item?.entry.tvTypes ?? rec?.tvTypes ?? const <String>[];
    final busy = manager.isBusy(internalName);

    Widget kv(String label, String? value) {
      if (value == null || value.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 120,
              child: Text(label,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: palette.muted)),
            ),
            Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
          ],
        ),
      );
    }

    final compatText = switch (item?.compatibility) {
      Compatibility.compatible => tr(context, 'ext.compat.ok'),
      Compatibility.unsupportedPlatform =>
        tr(context, 'ext.compat.unsupportedPlatform'),
      Compatibility.apiMismatch => tr(context, 'ext.compat.apiMismatch'),
      Compatibility.unsupportedPackage =>
        tr(context, 'ext.compat.unsupportedPackage'),
      null => null,
    };

    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scroll) => Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        decoration: BoxDecoration(
          color: palette.card,
          borderRadius: BorderRadius.circular(AppColors.radiusXl),
          border: Border.all(color: palette.border),
        ),
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.all(20),
          children: [
            Text(name, style: theme.textTheme.titleLarge),
            if (description != null) ...[
              const SizedBox(height: 8),
              Text(description,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: palette.muted)),
            ],
            const SizedBox(height: 16),
            kv(tr(context, 'ext.d.version'),
                rec == null
                    ? (item == null ? null : 'v${item.entry.version}')
                    : item != null && item.hasUpdate
                        ? 'v${rec.version} → v${item.entry.version}'
                        : 'v${rec.version}'),
            kv(tr(context, 'ext.d.author'), authors.join(', ')),
            kv(tr(context, 'ext.d.language'), language),
            kv(tr(context, 'ext.d.types'), types.join(', ')),
            kv(tr(context, 'ext.d.repository'), item == null
                ? null
                : [item.repo.name, ...item.otherRepoNames].join(', ')),
            kv(tr(context, 'ext.d.compatibility'), compatText),
            if (rec != null) ...[
              kv(tr(context, 'ext.d.providers'),
                  rec.providers.map((p) => p.name).join(', ')),
              kv(tr(context, 'ext.d.size'),
                  '${(rec.sizeBytes / 1024).round()} KB'),
              kv(tr(context, 'ext.d.installedAt'), formatStamp(rec.installedAt)),
              kv(tr(context, 'ext.d.lastInit'), formatStamp(rec.lastInitAt)),
              kv('SHA-256', rec.sha256.isEmpty ? null : rec.sha256),
              if (rec.lastError != null)
                kv(tr(context, 'ext.d.error'), rec.lastError),
              kv(tr(context, 'ext.d.settings'),
                  tr(context, 'ext.d.settingsNone')),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(tr(context, 'ext.d.enabled'),
                        style: theme.textTheme.titleSmall),
                  ),
                  Switch(
                    value: rec.enabled,
                    onChanged: busy
                        ? null
                        : (v) => runExtensionAction(
                              context,
                              () => manager.setEnabled(internalName, v),
                            ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            if (item != null && item.hasUpdate && !busy)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GradientButton(
                  label: trParams(context, 'ext.updateTo', {
                    'version': '${item.entry.version}',
                  }),
                  height: 48,
                  onPressed: () => runExtensionAction(
                    context,
                    () => manager.install(internalName),
                  ),
                ),
              ),
            if (item != null && rec == null && item.canInstall && !busy)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GradientButton(
                  label: tr(context, 'ext.install'),
                  height: 48,
                  onPressed: () => runExtensionAction(
                    context,
                    () => manager.install(internalName),
                  ),
                ),
              ),
            if (rec != null)
              GhostButton(
                label: tr(context, 'ext.uninstall'),
                height: 48,
                onPressed: busy ? null : () => _confirmUninstall(context, ref),
              ),
          ],
        ),
      ),
    );
  }
}
