import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/navigation_configuration.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/ui/navigation/navigation_destination_catalog.dart';

class MorePageView extends StatelessWidget {
  final NavigationConfiguration configuration;
  final ValueChanged<AppDestination> onOpenDestination;
  final VoidCallback? onConfigurationChanged;

  const MorePageView({
    super.key,
    required this.configuration,
    required this.onOpenDestination,
    this.onConfigurationChanged,
  });

  void _persistChange() => onConfigurationChanged?.call();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: configuration,
      builder: (context, _) => SingleChildScrollView(
        key: const ValueKey('more-page'),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.tr('navigation_current'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: configuration.destinations.length,
              onReorderItem: (oldIndex, newIndex) {
                if (configuration.move(oldIndex, newIndex)) {
                  _persistChange();
                }
              },
              itemBuilder: (context, index) {
                final destination = configuration.destinations[index];
                final definition = navigationDefinition(destination);
                return ListTile(
                  key: ValueKey('more-current-${destination.name}'),
                  minTileHeight: 56,
                  leading: Icon(definition.icon),
                  title: Text(context.tr(definition.labelKey)),
                  trailing: ReorderableDragStartListener(
                    index: index,
                    child: Semantics(
                      key: ValueKey('more-reorder-${destination.name}'),
                      button: true,
                      label: context.tr(
                        'navigation_reorder',
                        namedArgs: {
                          'destination': context.tr(definition.labelKey),
                        },
                      ),
                      child: const SizedBox.square(
                        dimension: 48,
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 20),
            Text(
              context.tr('navigation_all_functions'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            ...optionalNavigationDestinations.map((destination) {
              final definition = navigationDefinition(destination);
              final isFavorite = configuration.contains(destination);
              return Card(
                key: ValueKey('more-card-${destination.name}'),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        key: ValueKey('more-open-${destination.name}'),
                        onTap: () => onOpenDestination(destination),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 72),
                          child: ListTile(
                            leading: Icon(definition.icon),
                            title: Text(context.tr(definition.labelKey)),
                            subtitle:
                                Text(context.tr(definition.descriptionKey)),
                          ),
                        ),
                      ),
                    ),
                    Semantics(
                      key: ValueKey('more-favorite-${destination.name}'),
                      button: true,
                      toggled: isFavorite,
                      label: context.tr(
                        isFavorite
                            ? 'navigation_remove_favorite'
                            : 'navigation_add_favorite',
                        namedArgs: {
                          'destination': context.tr(definition.labelKey),
                        },
                      ),
                      child: IconButton(
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        tooltip: context.tr(
                          isFavorite
                              ? 'navigation_remove_favorite'
                              : 'navigation_add_favorite',
                          namedArgs: {
                            'destination': context.tr(definition.labelKey),
                          },
                        ),
                        icon: Icon(
                          isFavorite ? Icons.remove_circle : Icons.add_circle,
                        ),
                        onPressed: () {
                          if (!isFavorite) {
                            if (configuration.addFavorite(destination)) {
                              _persistChange();
                            }
                            return;
                          }
                          final previousIndex =
                              configuration.destinations.indexOf(destination);
                          if (!configuration.removeFavorite(destination)) {
                            return;
                          }
                          _persistChange();
                          ScaffoldMessenger.of(context)
                            ..hideCurrentSnackBar()
                            ..showSnackBar(
                              SnackBar(
                                content: Text(
                                  context.tr('navigation_favorite_removed'),
                                ),
                                action: SnackBarAction(
                                  label: context.tr('undo'),
                                  onPressed: () {
                                    configuration.insertFavorite(
                                      destination,
                                      previousIndex,
                                    );
                                    _persistChange();
                                  },
                                ),
                              ),
                            );
                        },
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
