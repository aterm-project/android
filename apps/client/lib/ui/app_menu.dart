import 'package:flutter/material.dart';

import 'app_density.dart';

double appMenuItemHeight(BuildContext context) =>
    AppDensity.of(context).menuItemHeight;

double appMenuIconSize(BuildContext context) =>
    AppDensity.of(context).menuIconSize;

/// Shared menu geometry without scaling text or shrinking touch hit targets.
PopupMenuItem<T> appMenuItem<T>(
  BuildContext context, {
  Key? key,
  T? value,
  bool enabled = true,
  VoidCallback? onTap,
  required Widget child,
}) => PopupMenuItem<T>(
  key: key,
  value: value,
  enabled: enabled,
  onTap: onTap,
  height: appMenuItemHeight(context),
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
  child: child,
);

class AppMenuLabel extends StatelessWidget {
  const AppMenuLabel(
    this.icon,
    this.label, {
    this.subtitle,
    this.color,
    super.key,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: appMenuIconSize(context), color: color),
      const SizedBox(width: 8),
      Flexible(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (subtitle != null)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppDensity.of(context).textSize(11),
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    ],
  );
}
