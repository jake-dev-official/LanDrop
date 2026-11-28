import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/pages/tabs/settings_tab_controller.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/native/completion_sound_helper.dart';
import 'package:localsend_app/util/native/device_info_helper.dart';
import 'package:localsend_app/util/native/macos_channel.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:localsend_app/widget/custom_dropdown_button.dart';
import 'package:localsend_app/widget/dialogs/quick_save_from_favorites_notice.dart';
import 'package:localsend_app/widget/dialogs/quick_save_notice.dart';
import 'package:localsend_app/widget/dialogs/text_field_with_actions.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:localsend_isolates/util/transfer_notification.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab();

  @override
  Widget build(BuildContext context) {
    return ViewModelBuilder(
      provider: (ref) => settingsTabControllerProvider,
      builder: (context, vm) {
        final ref = context.ref;
        return ResponsiveListView(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 16),
          children: [
            _SettingsSection(
              title: t.settingsTab.title,
              padding: EdgeInsets.zero,
              children: [
                _SettingsEntry(
                  label: t.settingsTab.network.alias,
                  child: TextFieldWithActions(
                    name: t.settingsTab.network.alias,
                    controller: vm.aliasController,
                    allowEmpty: false,
                    onSubmitted: (confirmedAlias) async {
                      final alias = confirmedAlias.trim();
                      vm.aliasController.text = alias;
                      await ref.notifier(settingsProvider).setAlias(alias);
                      if (ref.read(serverProvider) != null) {
                        try {
                          await ref.notifier(serverProvider).restartServerFromSettings();
                          unawaited(ref.global.dispatchAsync(StartSmartScan()));
                        } catch (e) {
                          if (context.mounted) {
                            context.showSnackBar(e.toString());
                          }
                        }
                      }
                    },
                    actions: [
                      Builder(
                        builder: (dialogContext) => Tooltip(
                          message: t.settingsTab.network.useSystemName,
                          child: IconButton(
                            onPressed: () async {
                              final systemName = await getDeviceName();
                              if (systemName == null || !dialogContext.mounted) {
                                return;
                              }

                              final isDialogOpen = ModalRoute.of(dialogContext)?.isCurrent ?? false;
                              if (!isDialogOpen) {
                                return;
                              }

                              vm.aliasController.text = systemName;
                            },
                            icon: const Icon(Icons.desktop_windows_rounded),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _SettingsEntry(
                  label: t.settingsTab.general.brightness,
                  child: CustomDropdownButton<ThemeMode>(
                    value: vm.settings.theme,
                    items: vm.themeModes.map((theme) {
                      return DropdownMenuItem(
                        value: theme,
                        alignment: Alignment.center,
                        child: Text(theme.humanName),
                      );
                    }).toList(),
                    onChanged: (theme) => vm.onChangeTheme(context, theme),
                  ),
                ),
                _SettingsEntry(
                  label: t.settingsTab.general.color,
                  child: CustomDropdownButton<ColorMode>(
                    value: vm.settings.colorMode,
                    items: vm.colorModes.map((colorMode) {
                      return DropdownMenuItem(
                        value: colorMode,
                        alignment: Alignment.center,
                        child: Text(colorMode.humanName, overflow: TextOverflow.ellipsis),
                      );
                    }).toList(),
                    onChanged: (colorMode) => vm.onChangeColorMode(context, colorMode),
                  ),
                ),
                _BooleanEntry(
                  label: t.settingsTab.receive.quickSave,
                  value: vm.settings.quickSave,
                  onChanged: (b) async {
                    final old = vm.settings.quickSave;
                    await ref.notifier(settingsProvider).setQuickSave(b);
                    if (b) {
                      await ref.notifier(settingsProvider).setQuickSaveFromFavorites(false);
                    }
                    if (!old && b && context.mounted) {
                      await QuickSaveNotice.open(context);
                    }
                  },
                ),
                _BooleanEntry(
                  label: t.settingsTab.receive.quickSaveFromFavorites,
                  value: vm.settings.quickSaveFromFavorites,
                  onChanged: (b) async {
                    final old = vm.settings.quickSaveFromFavorites;
                    await ref.notifier(settingsProvider).setQuickSaveFromFavorites(b);
                    if (b) {
                      await ref.notifier(settingsProvider).setQuickSave(false);
                    }
                    if (!old && b && context.mounted) {
                      await QuickSaveFromFavoritesNotice.open(context);
                    }
                  },
                ),
                _BooleanEntry(
                  label: 'Receive sound',
                  description: 'Play a sound when files finish arriving.',
                  value: vm.settings.playCompletionSound,
                  onChanged: (b) async {
                    await ref.notifier(settingsProvider).setPlayCompletionSound(b);
                    if (b) {
                      unawaited(
                        playTransferFinishSound(
                          preset: vm.settings.soundPreset,
                          customPath: vm.settings.customSoundPath,
                          respectStartGap: false,
                        ),
                      );
                    }
                  },
                ),
                if (vm.settings.playCompletionSound)
                  _SettingsEntry(
                    label: 'Notification sound',
                    child: CustomDropdownButton<String>(
                      value: transferSoundPresets.contains(vm.settings.soundPreset) ? vm.settings.soundPreset : 'default',
                      items: transferSoundPresets.map((preset) {
                        return DropdownMenuItem(
                          value: preset,
                          alignment: Alignment.center,
                          child: Text(transferSoundPresetLabel(preset), overflow: TextOverflow.ellipsis),
                        );
                      }).toList(),
                      onChanged: (preset) async {
                        if (preset == 'custom') {
                          String? customPath = vm.settings.customSoundPath;
                          if (customPath == null || customPath.isEmpty) {
                            try {
                              customPath = await pickAndSaveCustomSoundFile();
                            } on FormatException catch (e) {
                              if (context.mounted) {
                                context.showSnackBar(e.message);
                              }
                              return;
                            }
                            if (customPath == null) {
                              return;
                            }
                            await ref.notifier(settingsProvider).setCustomSoundPath(customPath);
                          }
                          await ref.notifier(settingsProvider).setSoundPreset('custom');
                          unawaited(
                            playTransferFinishSound(
                              preset: 'custom',
                              customPath: customPath,
                              respectStartGap: false,
                            ),
                          );
                          return;
                        }
                        await ref.notifier(settingsProvider).setSoundPreset(preset);
                        unawaited(
                          playTransferFinishSound(
                            preset: preset,
                            respectStartGap: false,
                          ),
                        );
                      },
                    ),
                  ),
                if (vm.settings.playCompletionSound && vm.settings.soundPreset == 'custom')
                  _ButtonEntry(
                    label: 'Custom sound file',
                    buttonLabel: (vm.settings.customSoundPath?.isNotEmpty ?? false) ? p.basename(vm.settings.customSoundPath!) : 'Choose file',
                    onTap: () async {
                      final String? picked;
                      try {
                        picked = await pickAndSaveCustomSoundFile();
                      } on FormatException catch (e) {
                        if (context.mounted) {
                          context.showSnackBar(e.message);
                        }
                        return;
                      }
                      if (picked == null) {
                        return;
                      }
                      await ref.notifier(settingsProvider).setCustomSoundPath(picked);
                      unawaited(
                        playTransferFinishSound(
                          preset: 'custom',
                          customPath: picked,
                          respectStartGap: false,
                        ),
                      );
                    },
                  ),
                if (checkPlatform([TargetPlatform.android]))
                  _BooleanEntry(
                    label: 'Always-on background receiver',
                    description: 'Keep a silent notification so LanDrop receives files while closed.',
                    value: vm.settings.backgroundKeepAlive,
                    onChanged: (b) async {
                      await ref.notifier(settingsProvider).setBackgroundKeepAlive(b);
                      TransferNotification.setKeepAlive(
                        enabled: b,
                        channelName: 'LanDrop Background',
                        idleTitle: 'LanDrop ready',
                        idleText: 'Listening on local network',
                      );
                    },
                  ),
                if (checkPlatformWithFileSystem())
                  _SettingsEntry(
                    label: t.settingsTab.receive.destination,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: Theme.of(context).inputDecorationTheme.fillColor,
                        shape: RoundedRectangleBorder(borderRadius: Theme.of(context).inputDecorationTheme.borderRadius),
                        foregroundColor: Theme.of(context).colorScheme.onSurface,
                      ),
                      onPressed: () async {
                        if (vm.settings.destination != null) {
                          await ref.notifier(settingsProvider).setDestination(null);
                          if (defaultTargetPlatform == TargetPlatform.macOS) {
                            await removeExistingDestinationAccess();
                          }
                          return;
                        }

                        final directory = await pickDirectoryPath();
                        if (directory != null) {
                          if (defaultTargetPlatform == TargetPlatform.macOS) {
                            await persistDestinationFolderAccess(directory);
                          }
                          await ref.notifier(settingsProvider).setDestination(directory);
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Text(vm.settings.destination ?? t.settingsTab.receive.downloads, style: Theme.of(context).textTheme.titleMedium),
                      ),
                    ),
                  ),
                if (checkPlatformWithGallery())
                  _BooleanEntry(
                    label: t.settingsTab.receive.saveToGallery,
                    value: vm.settings.saveToGallery,
                    onChanged: (b) async {
                      await ref.notifier(settingsProvider).setSaveToGallery(b);
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Version 1.0.0',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}

class _SettingsEntry extends StatelessWidget {
  final String label;
  final Widget child;
  final String? description;

  const _SettingsEntry({required this.label, required this.child, this.description});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 15),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (description != null)
                  Text(
                    description!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 150,
            child: child,
          ),
        ],
      ),
    );
  }
}

/// A specialized version of [_SettingsEntry].
class _BooleanEntry extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? description;

  const _BooleanEntry({
    required this.label,
    required this.value,
    required this.onChanged,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _SettingsEntry(
      label: label,
      description: description,
      child: Stack(
        children: [
          Container(
            width: double.infinity,
            height: 50,
            decoration: BoxDecoration(
              color: theme.inputDecorationTheme.fillColor,
              borderRadius: theme.inputDecorationTheme.borderRadius,
            ),
          ),
          Positioned.fill(
            child: Center(
              child: Switch(
                value: value,
                onChanged: onChanged,
                activeTrackColor: theme.colorScheme.primary,
                activeThumbColor: theme.colorScheme.onPrimary,
                inactiveThumbColor: theme.colorScheme.outline,
                inactiveTrackColor: theme.colorScheme.surface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A specialized version of [_SettingsEntry].
class _ButtonEntry extends StatelessWidget {
  final String label;
  final String buttonLabel;
  final void Function() onTap;

  const _ButtonEntry({
    required this.label,
    required this.buttonLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return _SettingsEntry(
      label: label,
      child: TextButton(
        style: TextButton.styleFrom(
          backgroundColor: Theme.of(context).inputDecorationTheme.fillColor,
          shape: RoundedRectangleBorder(borderRadius: Theme.of(context).inputDecorationTheme.borderRadius),
          foregroundColor: Theme.of(context).colorScheme.onSurface,
        ),
        onPressed: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Text(
            buttonLabel,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final EdgeInsets padding;

  const _SettingsSection({
    required this.title,
    required this.children,
    this.padding = const EdgeInsets.only(bottom: 15),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.only(left: 15, right: 15, top: 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

extension on ThemeMode {
  String get humanName {
    switch (this) {
      case ThemeMode.system:
        return t.settingsTab.general.brightnessOptions.system;
      case ThemeMode.light:
        return t.settingsTab.general.brightnessOptions.light;
      case ThemeMode.dark:
        return t.settingsTab.general.brightnessOptions.dark;
    }
  }
}

extension on ColorMode {
  String get humanName {
    return switch (this) {
      ColorMode.system => t.settingsTab.general.colorOptions.system,
      ColorMode.localsend => t.appName,
      ColorMode.oled => t.settingsTab.general.colorOptions.oled,
      ColorMode.yaru => 'Yaru',
      ColorMode.custom => t.settingsTab.general.colorOptions.custom,
    };
  }
}
