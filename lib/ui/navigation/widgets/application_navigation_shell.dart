import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:nai_casrand/data/models/navigation_configuration.dart';
import 'package:nai_casrand/data/models/navigation_request.dart';
import 'package:nai_casrand/ui/navigation/navigation_destination_catalog.dart';

class ApplicationNavigationShell extends StatefulWidget {
  final NavigationConfiguration configuration;
  final NavigationRequest navigationRequest;
  final Map<AppDestination, Widget> pages;
  final ValueChanged<AppDestination>? onDestinationOpened;
  final VoidCallback? onConfigurationChanged;
  final PreferredSizeWidget? appBar;
  final double desktopBreakpoint;

  const ApplicationNavigationShell({
    super.key,
    required this.configuration,
    required this.navigationRequest,
    required this.pages,
    this.onDestinationOpened,
    this.onConfigurationChanged,
    this.appBar,
    this.desktopBreakpoint = 640,
  });

  @override
  State<ApplicationNavigationShell> createState() =>
      ApplicationNavigationShellState();
}

class ApplicationNavigationShellState
    extends State<ApplicationNavigationShell> {
  static const _phoneEntryMinExtent = 88.0;
  static const _desktopRailWidth = 80.0;
  static const _desktopEntryExtent = 64.0;
  static const _desktopIndicatorWidth = 56.0;
  static const _desktopIndicatorHeight = 32.0;

  final ScrollController _phoneController = ScrollController();
  final ScrollController _desktopController = ScrollController();
  final Map<AppDestination, GlobalKey> _entryKeys = {
    for (final destination in AppDestination.values) destination: GlobalKey(),
  };

  AppDestination _contentDestination = AppDestination.generation;
  bool _returnToSettings = false;
  bool _phoneOverflow = false;
  bool _desktopOverflow = false;
  bool _phoneCanScrollBack = false;
  bool _phoneCanScrollForward = false;
  bool _desktopCanScrollBack = false;
  bool _desktopCanScrollForward = false;
  bool _phoneHintPlayed = false;
  bool _desktopLayout = false;
  double _phoneEntryExtent = _phoneEntryMinExtent;

  AppDestination get _selectedNavigationDestination =>
      !_returnToSettings && widget.configuration.contains(_contentDestination)
          ? _contentDestination
          : AppDestination.settings;

  @override
  void initState() {
    super.initState();
    widget.navigationRequest.requestedDestination.addListener(_handleRequest);
    widget.configuration.addListener(_handleConfigurationChange);
    _phoneController.addListener(_handlePhoneScroll);
    _desktopController.addListener(_handleDesktopScroll);
  }

  @override
  void didUpdateWidget(covariant ApplicationNavigationShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.navigationRequest != widget.navigationRequest) {
      oldWidget.navigationRequest.requestedDestination
          .removeListener(_handleRequest);
      widget.navigationRequest.requestedDestination.addListener(_handleRequest);
    }
    if (oldWidget.configuration != widget.configuration) {
      oldWidget.configuration.removeListener(_handleConfigurationChange);
      widget.configuration.addListener(_handleConfigurationChange);
    }
  }

  @override
  void dispose() {
    widget.navigationRequest.requestedDestination
        .removeListener(_handleRequest);
    widget.configuration.removeListener(_handleConfigurationChange);
    _phoneController.removeListener(_handlePhoneScroll);
    _desktopController.removeListener(_handleDesktopScroll);
    _phoneController.dispose();
    _desktopController.dispose();
    super.dispose();
  }

  void _handleRequest() {
    final destination = widget.navigationRequest.requestedDestination.value;
    if (destination == null) return;
    _open(
      destination,
      fromSettingsDirectory: widget.navigationRequest.openFromSettingsDirectory,
    );
    widget.navigationRequest.consume();
  }

  void _handleConfigurationChange() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
  }

  void _open(
    AppDestination destination, {
    bool fromSettingsDirectory = false,
  }) {
    final returnsToSettings = destination != AppDestination.settings &&
        (fromSettingsDirectory || !widget.configuration.contains(destination));
    if (_contentDestination == destination &&
        _returnToSettings == returnsToSettings) {
      widget.navigationRequest.consume();
      return;
    }
    setState(() {
      _contentDestination = destination;
      _returnToSettings = returnsToSettings;
    });
    widget.onDestinationOpened?.call(destination);
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
  }

  bool returnToSettingsIfTransient() {
    if (!_returnToSettings) return false;
    _open(AppDestination.settings);
    return true;
  }

  void _revealSelected() {
    if (!mounted) return;
    final controller = _desktopLayout ? _desktopController : _phoneController;
    if (!controller.hasClients) return;
    final index = widget.configuration.destinations.indexOf(
      _selectedNavigationDestination,
    );
    if (index < 0) return;
    final entryExtent =
        _desktopLayout ? _desktopEntryExtent : _phoneEntryExtent;
    final target = (index * entryExtent -
            (controller.position.viewportDimension - entryExtent) / 2)
        .clamp(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    );
    controller.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _updateOverflow(ScrollController controller, bool desktop) {
    if (!controller.hasClients) return;
    final position = controller.position;
    final overflow = position.maxScrollExtent > position.minScrollExtent;
    final canScrollBack = position.pixels > position.minScrollExtent + 0.5;
    final canScrollForward = position.pixels < position.maxScrollExtent - 0.5;
    final unchanged = desktop
        ? overflow == _desktopOverflow &&
            canScrollBack == _desktopCanScrollBack &&
            canScrollForward == _desktopCanScrollForward
        : overflow == _phoneOverflow &&
            canScrollBack == _phoneCanScrollBack &&
            canScrollForward == _phoneCanScrollForward;
    if (unchanged) return;
    setState(() {
      if (desktop) {
        _desktopOverflow = overflow;
        _desktopCanScrollBack = canScrollBack;
        _desktopCanScrollForward = canScrollForward;
      } else {
        _phoneOverflow = overflow;
        _phoneCanScrollBack = canScrollBack;
        _phoneCanScrollForward = canScrollForward;
      }
    });
    if (!desktop && overflow && !_phoneHintPlayed) {
      _phoneHintPlayed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _playPhoneHint());
    }
  }

  void _handlePhoneScroll() => _updateOverflow(_phoneController, false);

  void _handleDesktopScroll() => _updateOverflow(_desktopController, true);

  Future<void> _playPhoneHint() async {
    if (!mounted || !_phoneController.hasClients) return;
    final position = _phoneController.position;
    if (position.pixels != position.minScrollExtent) return;
    final hintOffset = (position.minScrollExtent + 24).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    await _phoneController.animateTo(
      hintOffset,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
    if (!mounted || !_phoneController.hasClients) return;
    await _phoneController.animateTo(
      _phoneController.position.minScrollExtent,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeInOut,
    );
  }

  Widget _content() {
    return widget.pages[_contentDestination] ?? const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= widget.desktopBreakpoint;
        _desktopLayout = desktop;
        if (!desktop && widget.configuration.destinations.isNotEmpty) {
          final destinationCount = widget.configuration.destinations.length;
          final fillWidth = constraints.maxWidth / destinationCount;
          if (destinationCount ==
              NavigationConfiguration.defaultDestinations.length) {
            _phoneEntryExtent = fillWidth;
          } else {
            _phoneEntryExtent = fillWidth < _phoneEntryMinExtent
                ? _phoneEntryMinExtent
                : fillWidth;
          }
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _updateOverflow(
            desktop ? _desktopController : _phoneController,
            desktop,
          );
        });
        return Scaffold(
          appBar: widget.appBar,
          body: Material(
            color: Theme.of(context).colorScheme.surface,
            child: desktop ? _buildDesktop() : _buildPhone(),
          ),
        );
      },
    );
  }

  Widget _buildPhone() {
    return Column(
      children: [
        Expanded(child: _content()),
        SizedBox(
          height: 72,
          child: Stack(
            children: [
              ListView(
                key: const ValueKey('phone-navigation-scroll'),
                controller: _phoneController,
                scrollDirection: Axis.horizontal,
                children: widget.configuration.destinations
                    .map((destination) => _entry(destination, phone: true))
                    .toList(growable: false),
              ),
              if (_phoneCanScrollBack)
                const PositionedDirectional(
                  start: 0,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: _OverflowCue(
                      key: ValueKey('phone-navigation-overflow-cue-start'),
                      icon: Icons.chevron_left,
                    ),
                  ),
                ),
              if (_phoneCanScrollForward)
                const PositionedDirectional(
                  end: 0,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: _OverflowCue(
                      key: ValueKey('phone-navigation-overflow-cue-end'),
                      icon: Icons.chevron_right,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDesktop() {
    final navigation = ListView(
      key: const ValueKey('desktop-navigation-scroll'),
      controller: _desktopController,
      padding: const EdgeInsets.only(top: 8),
      children: widget.configuration.destinations
          .map((destination) => _entry(destination, phone: false))
          .toList(growable: false),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: _desktopRailWidth,
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _desktopOverflow
                          ? Scrollbar(
                              key: const ValueKey(
                                'desktop-navigation-scrollbar',
                              ),
                              controller: _desktopController,
                              thumbVisibility: true,
                              child: navigation,
                            )
                          : navigation,
                    ),
                    if (_desktopCanScrollBack)
                      const PositionedDirectional(
                        start: 0,
                        end: 0,
                        top: 0,
                        child: IgnorePointer(
                          child: _OverflowCue(
                            key: ValueKey(
                              'desktop-navigation-overflow-cue-start',
                            ),
                            icon: Icons.keyboard_arrow_up,
                          ),
                        ),
                      ),
                    if (_desktopCanScrollForward)
                      const PositionedDirectional(
                        start: 0,
                        end: 0,
                        bottom: 0,
                        child: IgnorePointer(
                          child: _OverflowCue(
                            key: ValueKey(
                              'desktop-navigation-overflow-cue-end',
                            ),
                            icon: Icons.keyboard_arrow_down,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _content()),
      ],
    );
  }

  Widget _entry(AppDestination destination, {required bool phone}) {
    final definition = navigationDefinition(destination);
    final selected = destination == _selectedNavigationDestination;
    final label = context.tr(
      phone ? definition.shortLabelKey : definition.labelKey,
    );
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      key: _entryKeys[destination],
      selected: selected,
      button: true,
      label: label,
      child: Tooltip(
        message: context.tr(definition.labelKey),
        child: InkWell(
          key: ValueKey('navigation-${destination.name}'),
          onTap: () => _open(destination),
          child: Container(
            key: ValueKey('navigation-${destination.name}-indicator'),
            width: phone ? _phoneEntryExtent : null,
            height: phone ? 72 : _desktopEntryExtent,
            constraints: BoxConstraints(
              minWidth: phone ? 0 : _desktopRailWidth,
            ),
            padding: phone
                ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
                : EdgeInsets.zero,
            child: phone
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(definition.icon),
                      const SizedBox(height: 2),
                      Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Container(
                        key: ValueKey(
                          'navigation-${destination.name}-selection-indicator',
                        ),
                        width: _desktopIndicatorWidth,
                        height: _desktopIndicatorHeight,
                        decoration: selected
                            ? BoxDecoration(
                                color: colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(
                                  _desktopIndicatorHeight / 2,
                                ),
                              )
                            : null,
                        alignment: Alignment.center,
                        child: Icon(
                          definition.icon,
                          size: 24,
                          color: selected
                              ? colorScheme.onSecondaryContainer
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          label,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(color: colorScheme.onSurface),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _OverflowCue extends StatelessWidget {
  final IconData icon;

  const _OverflowCue({super.key, required this.icon});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: AlignmentDirectional.centerStart,
          end: AlignmentDirectional.centerEnd,
          colors: [color.withValues(alpha: 0), color],
        ),
      ),
      child: SizedBox.square(
        dimension: 48,
        child: Icon(icon),
      ),
    );
  }
}
