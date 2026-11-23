import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsax_flutter/iconsax_flutter.dart';
import 'package:material_ui/material_ui.dart';

import '../../extensions/core/manager.dart';
import '../../extensions/live_catalog.dart';
import '../../i18n/i18n.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import '../screen_helpers.dart';
import 'extensions_screen.dart' show formatStamp, runExtensionAction;

/// Settings > Providers > Extensions > Repositories: add a `repo.json`
/// (or `plugins.json`) URL, refresh it, remove it.
class ExtensionReposScreen extends ConsumerStatefulWidget {
  const ExtensionReposScreen({super.key});

  @override
  ConsumerState<ExtensionReposScreen> createState() =>
      _ExtensionReposScreenState();
}

class _ExtensionReposScreenState extends ConsumerState<ExtensionReposScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _adding = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final url = _controller.text.trim();
    if (url.isEmpty || _adding) return;
    setState(() => _adding = true);
    final manager = ref.read(extensionManagerProvider);
    if (!manager.isLoaded) await manager.load();
    if (!mounted) return;
    RepoRecord? added;
    final ok = await runExtensionAction(context, () async {
      added = await manager.addRepo(url);
    });
    if (!mounted) return;
    setState(() => _adding = false);
    if (ok && added != null) {
      _controller.clear();
      showSnack(
        context,
        trParams(context, 'ext.repoAdded', {
          'name': added!.name,
          'count': '${added!.entries.length}',
        }),
      );
    }
  }

  Future<void> _remove(RepoRecord repo) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr(ctx, 'ext.removeRepoTitle')),
        content: Text(trParams(ctx, 'ext.removeRepoBody', {'name': repo.name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(tr(ctx, 'common.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(tr(ctx, 'common.remove')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(extensionManagerProvider).removeRepo(repo.id);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final repos = ref.watch(extensionReposProvider);
    final manager = ref.read(extensionManagerProvider);

    return Scaffold(
      appBar: AppBar(title: Text(tr(context, 'ext.reposTitle'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Text(
            tr(context, 'ext.reposHelp'),
            style: theme.textTheme.bodyMedium?.copyWith(color: palette.muted),
          ),
          const SizedBox(height: 16),
          AppTextField(
            controller: _controller,
            hint: tr(context, 'ext.repoUrlHint'),
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _add(),
          ),
          const SizedBox(height: 12),
          GradientButton(
            label: tr(context, 'ext.addRepository'),
            loading: _adding,
            onPressed: _adding ? null : _add,
          ),
          const SizedBox(height: 24),
          for (final repo in repos)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: palette.card,
                  borderRadius: BorderRadius.circular(AppColors.radiusM),
                  border: Border.all(color: palette.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(repo.name,
                              style: theme.textTheme.titleSmall),
                        ),
                        if (manager.isRefreshing(repo.id))
                          const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else ...[
                          IconButton(
                            tooltip: tr(context, 'ext.refreshRepo'),
                            icon: const Icon(Iconsax.refresh_copy),
                            onPressed: () => runExtensionAction(
                              context,
                              () async {
                                await manager.refreshRepo(repo.id);
                              },
                            ),
                          ),
                          IconButton(
                            tooltip: tr(context, 'common.remove'),
                            icon: const Icon(Iconsax.trash_copy),
                            onPressed: () => _remove(repo),
                          ),
                        ],
                      ],
                    ),
                    Text(repo.url,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: palette.muted)),
                    const SizedBox(height: 6),
                    Text(
                      trParams(context, 'ext.repoSummary', {
                        'count': '${repo.entries.length}',
                        'lists': '${repo.pluginListUrls.length}',
                        'time': formatStamp(repo.lastRefreshedAt),
                      }),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: palette.muted),
                    ),
                    if (repo.skipped > 0 || repo.duplicates > 0)
                      Text(
                        trParams(context, 'ext.repoSkipped', {
                          'skipped': '${repo.skipped}',
                          'duplicates': '${repo.duplicates}',
                        }),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: palette.muted),
                      ),
                    if (repo.lastError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          repo.lastError!,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: AppColors.brand),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
