import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:fitkey_core/fitkey_core.dart' show ApiException, resolveMediaUrl, initials;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

// ---------------------------------------------------------------------------
// Interaction
// ---------------------------------------------------------------------------

/// Shrinks slightly while pressed — the tactile feel of food-delivery apps.
class Tap extends StatefulWidget {
  const Tap({super.key, required this.child, this.onTap, this.scale = 0.97, this.haptic = true});

  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final bool haptic;

  @override
  State<Tap> createState() => _TapState();
}

class _TapState extends State<Tap> {
  bool _down = false;

  void _set(bool v) {
    if (widget.onTap != null && _down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptic) HapticFeedback.selectionClick();
              widget.onTap!();
            },
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Surfaces
// ---------------------------------------------------------------------------

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.radius = 20,
    this.color = AppColors.surface,
    this.border = false,
    this.shadow = true,
    this.gradient,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color color;
  final bool border;
  final bool shadow;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: gradient == null ? color : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(radius),
        border: border ? Border.all(color: AppColors.line) : null,
        boxShadow: shadow ? AppShadows.card : null,
      ),
      child: child,
    );
    return onTap == null ? box : Tap(onTap: onTap, child: box);
  }
}

/// Soft coloured circle holding an icon.
class IconBubble extends StatelessWidget {
  const IconBubble(this.icon, {super.key, this.color = AppColors.primary, this.bg, this.size = 44, this.iconSize});

  final IconData icon;
  final Color color;
  final Color? bg;
  final double size;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg ?? color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(size * 0.32)),
      child: Icon(icon, color: color, size: iconSize ?? size * 0.5),
    );
  }
}

/// Small rounded label: "OPEN NOW", "20% OFF", "Beginner"…
class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.color = AppColors.primary, this.bg, this.icon, this.solid = false, this.dense = false});

  final String label;
  final Color color;
  final Color? bg;
  final IconData? icon;
  final bool solid;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final fg = solid ? Colors.white : color;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 7 : 9, vertical: dense ? 3 : 4.5),
      decoration: BoxDecoration(
        color: solid ? color : (bg ?? color.withValues(alpha: 0.1)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: dense ? 11 : 13, color: fg), const SizedBox(width: 4)],
        Text(label,
            style: TextStyle(
                fontSize: dense ? 10.5 : 11.5, fontWeight: FontWeight.w800, color: fg, letterSpacing: 0.2, height: 1.1)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

/// Network photo with shimmer while loading and a bundled photo when missing or broken.
class NetImage extends StatelessWidget {
  const NetImage(this.url, {super.key, required this.fallback, this.height, this.width, this.radius = 0, this.fit = BoxFit.cover});

  final String? url;

  /// Asset path shown when [url] is null or fails to load.
  final String fallback;
  final double? height;
  final double? width;
  final double radius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final resolved = resolveMediaUrl(url);
    final asset = Image.asset(fallback, height: height, width: width ?? double.infinity, fit: fit);
    final child = resolved == null
        ? asset
        : CachedNetworkImage(
            imageUrl: resolved,
            height: height,
            width: width ?? double.infinity,
            fit: fit,
            fadeInDuration: const Duration(milliseconds: 250),
            placeholder: (_, _) => Shimmer(child: Container(height: height, width: width, color: AppColors.surfaceAlt)),
            errorWidget: (_, _, _) => asset,
          );
    return radius == 0 ? child : ClipRRect(borderRadius: BorderRadius.circular(radius), child: child);
  }
}

/// Darkening gradient so white text stays readable on photos.
class PhotoScrim extends StatelessWidget {
  const PhotoScrim({super.key, this.strength = 0.75, this.from = Alignment.topCenter});

  final double strength;
  final Alignment from;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: from,
          end: Alignment(-from.x, -from.y),
          colors: [Colors.transparent, Colors.black.withValues(alpha: strength)],
          stops: const [0.35, 1],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Loading skeletons
// ---------------------------------------------------------------------------

class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (rect) => LinearGradient(
          colors: const [Color(0xFFEDEEF3), Color(0xFFF8F8FB), Color(0xFFEDEEF3)],
          stops: const [0.1, 0.5, 0.9],
          begin: Alignment(-1.5 + 3 * _c.value, -0.2),
          end: Alignment(-0.5 + 3 * _c.value, 0.2),
        ).createShader(rect),
        child: child,
      ),
    );
  }
}

class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.height = 16, this.width, this.radius = 10});
  final double height;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        width: width,
        decoration: BoxDecoration(color: AppColors.surfaceAlt, borderRadius: BorderRadius.circular(radius)),
      );
}

/// Generic list-of-cards skeleton used while a screen's first load is in flight.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.count = 4, this.itemHeight = 96, this.padding = const EdgeInsets.all(16)});
  final int count;
  final double itemHeight;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        padding: padding,
        itemCount: count,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (_, _) => Row(children: [
          SkeletonBox(height: itemHeight, width: itemHeight, radius: 16),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SkeletonBox(height: 16, width: 160),
              const SizedBox(height: 10),
              const SkeletonBox(height: 12, width: 110),
              const SizedBox(height: 10),
              SkeletonBox(height: 12, width: itemHeight),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Headings
// ---------------------------------------------------------------------------

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.subtitle, this.action, this.onAction, this.padding});

  final String title;
  final String? subtitle;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(0, 28, 0, 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: AppColors.text)),
            if (subtitle != null) ...[
              const SizedBox(height: 3),
              Text(subtitle!, style: const TextStyle(fontSize: 13, color: AppColors.text2, fontWeight: FontWeight.w500)),
            ],
          ]),
        ),
        if (action != null)
          Tap(
            onTap: onAction,
            child: Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 2),
              child: Row(children: [
                Text(action!, style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w800, fontSize: 13.5)),
                const Icon(Icons.chevron_right_rounded, color: AppColors.primary, size: 20),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Centered spaced-caps divider title — "──── WHAT'S ON YOUR MIND? ────".
class DividerTitle extends StatelessWidget {
  const DividerTitle(this.title, {super.key, this.padding = const EdgeInsets.fromLTRB(0, 28, 0, 16)});
  final String title;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(children: [
        const Expanded(child: Divider(color: AppColors.line)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(title.toUpperCase(),
              style: const TextStyle(fontSize: 12, letterSpacing: 2.2, fontWeight: FontWeight.w700, color: AppColors.text3)),
        ),
        const Expanded(child: Divider(color: AppColors.line)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------

/// Primary call to action with a built-in busy state.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.color = AppColors.primary,
    this.foreground = Colors.white,
    this.height = 54,
    this.trailing,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final Color color;
  final Color foreground;
  final double height;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(backgroundColor: color, foregroundColor: foreground, minimumSize: Size.fromHeight(height)),
        onPressed: busy ? null : onPressed,
        child: busy
            ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: foreground))
            : Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
                Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ]),
      ),
    );
  }
}

/// Sticky bottom bar holding the screen's main action (cart / booking style).
class BottomActionBar extends StatelessWidget {
  const BottomActionBar({super.key, required this.child, this.leading});
  final Widget child;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        boxShadow: [BoxShadow(color: Color(0x141A1B25), blurRadius: 20, offset: Offset(0, -4))],
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: SafeArea(
        top: false,
        child: leading == null
            ? child
            : Row(children: [leading!, const SizedBox(width: 14), Expanded(child: child)]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// States
// ---------------------------------------------------------------------------

class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.icon, required this.title, this.message, this.action, this.color = AppColors.primary});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(alignment: Alignment.center, children: [
              Container(decoration: BoxDecoration(color: color.withValues(alpha: 0.07), shape: BoxShape.circle)),
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
              ),
              Icon(icon, size: 40, color: color),
              Positioned(top: 10, right: 14, child: _dot(color, 8)),
              Positioned(bottom: 16, left: 8, child: _dot(color, 6)),
            ]),
          ),
          const SizedBox(height: 18),
          Text(title,
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.text2, height: 1.45)),
          ],
          if (action != null) ...[const SizedBox(height: 22), action!],
        ]),
      ),
    );
  }

  Widget _dot(Color c, double s) =>
      Container(width: s, height: s, decoration: BoxDecoration(color: c.withValues(alpha: 0.4), shape: BoxShape.circle));
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});
  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyView(
      icon: Icons.wifi_off_rounded,
      color: AppColors.text2,
      title: 'Something went wrong',
      message: friendlyError(error),
      action: onRetry == null
          ? null
          : SizedBox(
              width: 160,
              child: OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('Try again')),
            ),
    );
  }
}

/// FutureBuilder with skeleton loading and a retryable error state.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.future, required this.builder, this.onRetry, this.loading});

  final Future<T> future;
  final Widget Function(BuildContext context, T data) builder;
  final VoidCallback? onRetry;
  final Widget? loading;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return loading ?? const SkeletonList();
        if (snap.hasError) return ErrorView(error: snap.error!, onRetry: onRetry);
        return builder(context, snap.data as T);
      },
    );
  }
}

String friendlyError(Object e) => e is ApiException ? e.message : 'Please check your connection and try again.';

void toast(BuildContext context, String message, {bool error = false, IconData? icon}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      backgroundColor: error ? AppColors.red : AppColors.ink,
      content: Row(children: [
        Icon(icon ?? (error ? Icons.error_outline_rounded : Icons.check_circle_rounded),
            color: error ? Colors.white : AppColors.lime, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
      ]),
    ));
}

// ---------------------------------------------------------------------------
// People
// ---------------------------------------------------------------------------

const _avatarGradients = [
  [Color(0xFFFF7A45), Color(0xFFFF4B2B)],
  [Color(0xFF7C5CFF), Color(0xFF5B8CFF)],
  [Color(0xFF14B8A6), Color(0xFF1BA672)],
  [Color(0xFFFF4F9A), Color(0xFFFF7A9A)],
  [Color(0xFFFFA41B), Color(0xFFFF7A45)],
  [Color(0xFF3D7BFF), Color(0xFF14B8A6)],
];

class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.name, this.size = 44, this.photoUrl});

  final String? name;
  final double size;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) {
    final g = _avatarGradients[(name ?? '').codeUnits.fold<int>(0, (a, b) => a + b) % _avatarGradients.length];
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: g)),
      alignment: Alignment.center,
      child: Text(initials(name),
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: size * 0.36, letterSpacing: 0.5)),
    );
    final resolved = resolveMediaUrl(photoUrl);
    if (resolved == null) return fallback;
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: resolved,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => fallback,
        errorWidget: (_, _, _) => fallback,
      ),
    );
  }
}

/// Mansi's avatar: a softly breathing gradient orb.
class MansiAvatar extends StatefulWidget {
  const MansiAvatar({super.key, this.size = 40, this.animate = true});
  final double size;
  final bool animate;

  @override
  State<MansiAvatar> createState() => _MansiAvatarState();
}

class _MansiAvatarState extends State<MansiAvatar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 6));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(
            transform: GradientRotation(_c.value * 2 * math.pi),
            colors: const [Color(0xFF7C5CFF), Color(0xFFFF4F9A), Color(0xFFFF8A3D), Color(0xFF7C5CFF)],
          ),
          boxShadow: [BoxShadow(color: const Color(0xFFFF4F9A).withValues(alpha: 0.3), blurRadius: s * 0.3)],
        ),
        alignment: Alignment.center,
        child: Container(
          width: s * 0.78,
          height: s * 0.78,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: const Alignment(-0.35, -0.4),
              colors: [Colors.white.withValues(alpha: 0.95), const Color(0xFFFFE3F0)],
            ),
          ),
          alignment: Alignment.center,
          child: ShaderMask(
            shaderCallback: (r) => AppColors.mansiGradient.createShader(r),
            child: Text('M',
                style: TextStyle(fontSize: s * 0.4, fontWeight: FontWeight.w800, color: Colors.white, height: 1)),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

/// Search field whose hint cycles through suggestions ("Search for 'yoga'").
class RotatingSearchBar extends StatefulWidget {
  const RotatingSearchBar({
    super.key,
    required this.hints,
    this.onTap,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.trailing,
  });

  final List<String> hints;
  final VoidCallback? onTap;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final Widget? trailing;

  @override
  State<RotatingSearchBar> createState() => _RotatingSearchBarState();
}

class _RotatingSearchBarState extends State<RotatingSearchBar> {
  int _i = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 2600), (_) {
      if (mounted) setState(() => _i = (_i + 1) % widget.hints.length);
    });
    widget.controller?.addListener(_onText);
  }

  void _onText() => setState(() {});

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller?.removeListener(_onText);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editable = widget.onTap == null;
    final empty = widget.controller?.text.isEmpty ?? true;
    final hint = AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      transitionBuilder: (child, a) => SlideTransition(
        position: Tween(begin: const Offset(0, 0.6), end: Offset.zero).animate(a),
        child: FadeTransition(opacity: a, child: child),
      ),
      child: Text('Search ${widget.hints[_i]}',
          key: ValueKey(_i),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.text3, fontWeight: FontWeight.w500, fontSize: 14.5)),
    );

    return Tap(
      onTap: widget.onTap,
      scale: 0.99,
      haptic: false,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.line),
          boxShadow: AppShadows.soft,
        ),
        child: Row(children: [
          const Icon(Icons.search_rounded, color: AppColors.primary, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: !editable
                ? Align(alignment: Alignment.centerLeft, child: hint)
                : Stack(alignment: Alignment.centerLeft, children: [
                    if (empty) IgnorePointer(child: hint),
                    TextField(
                      controller: widget.controller,
                      autofocus: widget.autofocus,
                      onChanged: widget.onChanged,
                      onSubmitted: widget.onSubmitted,
                      textInputAction: TextInputAction.search,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
                      decoration: const InputDecoration(
                        isCollapsed: true,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                  ]),
          ),
          if (editable && !empty)
            GestureDetector(
              onTap: () {
                widget.controller!.clear();
                widget.onChanged?.call('');
                widget.onSubmitted?.call('');
              },
              child: const Icon(Icons.close_rounded, color: AppColors.text3, size: 20),
            ),
          if (widget.trailing != null) ...[
            Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 10), color: AppColors.line),
            widget.trailing!,
          ],
        ]),
      ),
    );
  }
}

/// Horizontally scrolling filter chips (single select).
class ChoiceChips<T> extends StatelessWidget {
  const ChoiceChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    required this.label,
    this.icon,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final List<T> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final String Function(T) label;
  final IconData? Function(T)? icon;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        padding: padding,
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final o = options[i];
          final on = o == selected;
          final ic = icon?.call(o);
          return Tap(
            onTap: () => onSelected(o),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: on ? AppColors.ink : AppColors.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: on ? AppColors.ink : AppColors.line),
              ),
              alignment: Alignment.center,
              child: Row(children: [
                if (ic != null) ...[Icon(ic, size: 16, color: on ? Colors.white : AppColors.text2), const SizedBox(width: 6)],
                Text(label(o),
                    style: TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13, color: on ? Colors.white : AppColors.text)),
              ]),
            ),
          );
        },
      ),
    );
  }
}

/// Blinkit-style ADD / − n + stepper.
class QtyStepper extends StatelessWidget {
  const QtyStepper({super.key, required this.qty, required this.onChanged, this.max = 99, this.compact = false});

  final int qty;
  final ValueChanged<int> onChanged;
  final int max;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final h = compact ? 34.0 : 40.0;
    if (qty == 0) {
      return Tap(
        onTap: max > 0 ? () => onChanged(1) : null,
        child: Container(
          height: h,
          width: compact ? 72 : 88,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: max > 0 ? AppColors.greenSoft : AppColors.surfaceAlt,
            border: Border.all(color: max > 0 ? AppColors.green : AppColors.line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(max > 0 ? 'ADD' : 'SOLD OUT',
              style: TextStyle(
                  color: max > 0 ? AppColors.green : AppColors.text3, fontWeight: FontWeight.w800, fontSize: compact ? 12 : 13)),
        ),
      );
    }
    Widget btn(IconData i, VoidCallback? f) => InkResponse(
          onTap: f == null
              ? null
              : () {
                  HapticFeedback.selectionClick();
                  f();
                },
          radius: 18,
          child: SizedBox(width: compact ? 26 : 32, height: h, child: Icon(i, color: Colors.white, size: 18)),
        );
    return Container(
      height: h,
      decoration: BoxDecoration(color: AppColors.green, borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        btn(Icons.remove_rounded, () => onChanged(qty - 1)),
        SizedBox(
          width: compact ? 20 : 24,
          child: Text('$qty',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
        ),
        btn(Icons.add_rounded, qty < max ? () => onChanged(qty + 1) : null),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Data display
// ---------------------------------------------------------------------------

class MetricTile extends StatelessWidget {
  const MetricTile({super.key, required this.label, required this.value, required this.icon, this.color = AppColors.primary, this.unit});

  final String label;
  final String value;
  final String? unit;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconBubble(icon, color: color, size: 34),
        const SizedBox(height: 12),
        Text.rich(
          TextSpan(children: [
            TextSpan(text: value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
            if (unit != null)
              TextSpan(text: ' $unit', style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w600)),
          ]),
          maxLines: 1,
        ),
        const SizedBox(height: 2),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// Price with optional struck-through MRP and discount, e.g. ₹1,499  ₹1,999  25% OFF.
class PriceText extends StatelessWidget {
  const PriceText({super.key, required this.price, this.mrp, this.size = 16});
  final String price;
  final String? mrp;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
      Text(price, style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: AppColors.text)),
      if (mrp != null)
        Text(mrp!,
            style: TextStyle(
                fontSize: size * 0.78,
                color: AppColors.text3,
                decoration: TextDecoration.lineThrough,
                fontWeight: FontWeight.w500)),
    ]);
  }
}

/// Big photo banner with a scrim, title and CTA — used for promos and hero cards.
class PhotoBanner extends StatelessWidget {
  const PhotoBanner({
    super.key,
    required this.image,
    required this.title,
    this.eyebrow,
    this.subtitle,
    this.cta,
    this.onTap,
    this.height = 170,
    this.tint,
  });

  final String image;
  final String title;
  final String? eyebrow;
  final String? subtitle;
  final String? cta;
  final VoidCallback? onTap;
  final double height;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return Tap(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: SizedBox(
          height: height,
          child: Stack(fit: StackFit.expand, children: [
            Image.asset(image, fit: BoxFit.cover),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [(tint ?? Colors.black).withValues(alpha: 0.88), (tint ?? Colors.black).withValues(alpha: 0.05)],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              // Shrinks the copy slightly on narrow phones / large text instead of overflowing.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                if (eyebrow != null)
                  Text(eyebrow!.toUpperCase(),
                      style: const TextStyle(
                          color: AppColors.lime, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
                const SizedBox(height: 6),
                SizedBox(
                  width: 230,
                  child: Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800, height: 1.15, letterSpacing: -0.4)),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 220,
                    child: Text(subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 12.5, height: 1.35)),
                  ),
                ],
                if (cta != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(cta!, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: AppColors.ink)),
                      const SizedBox(width: 4),
                      const Icon(Icons.arrow_forward_rounded, size: 16, color: AppColors.ink),
                    ]),
                  ),
                ],
              ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Opens a rounded modal bottom sheet that resizes with the keyboard.
Future<T?> showAppSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: builder(ctx),
    ),
  );
}

/// Pushes a screen with the platform page transition.
Future<T?> push<T>(BuildContext context, Widget screen) =>
    Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => screen));
