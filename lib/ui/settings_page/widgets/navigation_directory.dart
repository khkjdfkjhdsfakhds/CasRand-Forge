import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/navigation_configuration.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/ui/navigation/navigation_destination_catalog.dart';

class NavigationDirectory extends StatelessWidget {
  final NavigationConfiguration configuration;
  final bool showHeader;
  final Map<AppDestination, GlobalKey> destinationKeys;
  final ValueChanged<AppDestination> onOpenDestination;
  final ValueChanged<({AppDestination destination, bool enabled})>
      onEnabledChanged;
  final void Function(int oldIndex, int newIndex) onReorder;

  const NavigationDirectory({
    super.key,
    required this.configuration,
    this.showHeader = true,
    required this.destinationKeys,
    required this.onOpenDestination,
    required this.onEnabledChanged,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: configuration,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeader)
            ListTile(
              key: const Key('navigation-directory-title'),
              leading: const Icon(Icons.view_sidebar_outlined),
              title: Text(context.tr('navigation_directory')),
              subtitle: Text(context.tr('navigation_directory_hint')),
            ),
          ReorderableListView.builder(
            key: const Key('navigation-directory-list'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: configuration.orderedDestinations.length,
            onReorderItem: onReorder,
            itemBuilder: (context, index) {
              final destination = configuration.orderedDestinations[index];
              final definition = navigationDefinition(destination);
              final label = context.tr(definition.labelKey);
              final anchorKey = destinationKeys[destination]!;
              return Column(
                key: ValueKey('navigation-directory-item-${destination.name}'),
                children: [
                  Container(
                    key: anchorKey,
                    constraints: const BoxConstraints(minHeight: 64),
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            key: ValueKey(
                              'navigation-directory-open-${destination.name}',
                            ),
                            onTap: () => onOpenDestination(destination),
                            child: ListTile(
                              leading: Icon(definition.icon),
                              title: Text(label),
                              subtitle: Text(
                                context.tr(definition.descriptionKey),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                        if (destination.isMandatory)
                          Tooltip(
                            key: ValueKey(
                              'navigation-directory-required-${destination.name}',
                            ),
                            message: context.tr(
                              'navigation_required',
                              namedArgs: {'destination': label},
                            ),
                            child: const SizedBox.square(
                              dimension: 48,
                              child: Icon(Icons.lock_outline),
                            ),
                          )
                        else
                          Switch(
                            key: ValueKey(
                              'navigation-directory-toggle-${destination.name}',
                            ),
                            value: configuration.contains(destination),
                            onChanged: (enabled) => onEnabledChanged((
                              destination: destination,
                              enabled: enabled,
                            )),
                          ),
                        ReorderableDragStartListener(
                          key: ValueKey(
                            'navigation-directory-reorder-${destination.name}',
                          ),
                          index: index,
                          child: Semantics(
                            button: true,
                            label: context.tr(
                              'navigation_reorder',
                              namedArgs: {'destination': label},
                            ),
                            child: const SizedBox.square(
                              dimension: 48,
                              child: Icon(Icons.drag_handle),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
