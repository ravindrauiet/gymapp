import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '../../widgets/mini_markdown.dart';

class _Msg {
  _Msg({required this.role, required this.content, this.image});

  final String role; // 'user' | 'assistant'
  final String content;
  final Uint8List? image;
  bool failed = false;
}

/// The conversation survives leaving and reopening the screen during this app session.
final List<_Msg> _history = [];

/// Mansi — the member's AI fitness & nutrition coach (GPT via the FITKEY API, personalised server-side).
class AiCoachScreen extends StatefulWidget {
  const AiCoachScreen({super.key, this.initialPrompt});

  /// Sent automatically when the screen opens (from the suggestion chips on Home).
  final String? initialPrompt;

  @override
  State<AiCoachScreen> createState() => _AiCoachScreenState();
}

class _AiCoachScreenState extends State<AiCoachScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  final _picker = ImagePicker();
  bool _sending = false;
  Uint8List? _pendingImage;
  UserGoal? _goal;

  static const _suggestions = [
    (Icons.restaurant_menu_rounded, AppColors.green, 'Plan my meals for today', 'Based on my calorie & protein targets'),
    (Icons.fitness_center_rounded, AppColors.primary, 'Build me a 4-day workout split', 'For my goal, with sets & reps'),
    (Icons.egg_alt_rounded, AppColors.amber, 'High-protein vegetarian ideas', 'Indian food, budget friendly'),
    (Icons.local_fire_department_rounded, AppColors.red, 'How fast can I safely lose fat?', 'Realistic timeline for me'),
    (Icons.self_improvement_rounded, AppColors.purple, 'A 10-minute mobility routine', 'For stiff hips & lower back'),
    (Icons.bedtime_rounded, AppColors.blue, 'Help me recover better', 'Sleep, soreness & rest days'),
  ];

  @override
  void initState() {
    super.initState();
    context.read<Session>().api.goal().then((g) {
      if (mounted) setState(() => _goal = g);
    }).catchError((_) {});
    if (widget.initialPrompt != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _send(widget.initialPrompt));
    } else {
      _scrollToEnd(jump: true);
    }
  }

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToEnd({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      jump ? _scroll.jumpTo(end) : _scroll.animateTo(end, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _text.text).trim();
    final image = _pendingImage;
    if ((text.isEmpty && image == null) || _sending) return;
    HapticFeedback.lightImpact();
    _text.clear();
    setState(() {
      _history.add(_Msg(role: 'user', content: text.isEmpty ? 'What do you think of this photo?' : text, image: image));
      _pendingImage = null;
      _sending = true;
    });
    _scrollToEnd();
    await _ask(image);
  }

  Future<void> _ask(Uint8List? image) async {
    final api = context.read<Session>().api;
    try {
      final payload = _history
          .where((m) => !m.failed)
          .map((m) => {'role': m.role, 'content': m.content})
          .toList();
      final reply = await api.sendChatMessage(payload, imageBase64: image == null ? null : base64Encode(image));
      if (!mounted) return;
      setState(() {
        _history.add(_Msg(role: 'assistant', content: reply));
        _sending = false;
      });
      _scrollToEnd();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _history.last.failed = true;
        _sending = false;
      });
      toast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _retry(_Msg m) async {
    if (_sending) return;
    setState(() {
      m.failed = false;
      _sending = true;
    });
    await _ask(m.image);
  }

  Future<void> _pickImage() async {
    final source = await showAppSheet<ImageSource>(
      context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Show Mansi a photo', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text('Your meal, a nutrition label, your form or a piece of equipment.',
                style: TextStyle(color: AppColors.text2)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: _sourceTile(ctx, Icons.photo_camera_rounded, 'Camera', ImageSource.camera)),
              const SizedBox(width: 12),
              Expanded(child: _sourceTile(ctx, Icons.photo_library_rounded, 'Gallery', ImageSource.gallery)),
            ]),
          ]),
        ),
      ),
    );
    if (source == null) return;
    try {
      final file = await _picker.pickImage(source: source, maxWidth: 1280, maxHeight: 1280, imageQuality: 80);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (mounted) setState(() => _pendingImage = bytes);
    } catch (_) {
      if (mounted) toast(context, 'Could not open the ${source == ImageSource.camera ? 'camera' : 'gallery'}', error: true);
    }
  }

  Widget _sourceTile(BuildContext ctx, IconData icon, String label, ImageSource s) => AppCard(
        border: true,
        shadow: false,
        onTap: () => Navigator.pop(ctx, s),
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Column(children: [
          IconBubble(icon, color: AppColors.purple, size: 48),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );

  void _newChat() {
    if (_history.isEmpty) return;
    HapticFeedback.mediumImpact();
    setState(_history.clear);
  }

  @override
  Widget build(BuildContext context) {
    final name = context.select<Session, String?>((s) => s.user?.firstName);
    return Scaffold(
      backgroundColor: const Color(0xFFF7F5FF),
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          const MansiAvatar(size: 38),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Mansi', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            Row(children: [
              Container(
                  width: 7, height: 7, decoration: const BoxDecoration(color: AppColors.green, shape: BoxShape.circle)),
              const SizedBox(width: 5),
              Text(_sending ? 'typing…' : 'AI fitness & diet coach',
                  style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w600)),
            ]),
          ]),
        ]),
        actions: [
          if (_history.isNotEmpty)
            IconButton(tooltip: 'New chat', icon: const Icon(Icons.edit_square), onPressed: _newChat),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(children: [
        if (_goal != null) _GoalStrip(goal: _goal!),
        Expanded(
          child: _history.isEmpty
              ? _Welcome(name: name, suggestions: _suggestions, onPick: _send)
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
                  itemCount: _history.length + (_sending ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i == _history.length) return const _Typing();
                    final m = _history[i];
                    return _Bubble(msg: m, onRetry: () => _retry(m));
                  },
                ),
        ),
        _Composer(
          controller: _text,
          sending: _sending,
          image: _pendingImage,
          onRemoveImage: () => setState(() => _pendingImage = null),
          onAttach: _pickImage,
          onSend: () => _send(),
        ),
      ]),
    );
  }
}

class _GoalStrip extends StatelessWidget {
  const _GoalStrip({required this.goal});
  final UserGoal goal;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: const BoxDecoration(color: AppColors.surface, border: Border(bottom: BorderSide(color: AppColors.line))),
      child: Row(children: [
        const Icon(Icons.track_changes_rounded, size: 16, color: AppColors.purple),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Personalised for ${goal.goalLabel.split('(').first.trim().toLowerCase()} · ${goal.dailyCalorieTarget} kcal · ${goal.dailyProteinG} g protein',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppColors.text2),
          ),
        ),
      ]),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.name, required this.suggestions, required this.onPick});
  final String? name;
  final List<(IconData, Color, String, String)> suggestions;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.fromLTRB(16, 28, 16, 16), children: [
      const Center(child: MansiAvatar(size: 84)),
      const SizedBox(height: 18),
      Text('Hi ${name ?? 'there'}, I\'m Mansi ✨',
          textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
      const SizedBox(height: 8),
      const Text(
        'I know your goal, your targets and what you\'ve eaten today — ask me about workouts, food, form or recovery. You can even send me a photo.',
        textAlign: TextAlign.center,
        style: TextStyle(color: AppColors.text2, height: 1.5),
      ),
      const SizedBox(height: 24),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.25,
        children: [
          for (final (icon, color, title, sub) in suggestions)
            AppCard(
              onTap: () => onPick(title),
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                IconBubble(icon, color: color, size: 34),
                const Spacer(),
                Text(title,
                    maxLines: 2,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5, height: 1.25)),
                const SizedBox(height: 2),
                Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: AppColors.text3, fontWeight: FontWeight.w600)),
              ]),
            ),
        ],
      ),
      const SizedBox(height: 18),
      const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.health_and_safety_outlined, size: 14, color: AppColors.text3),
        SizedBox(width: 5),
        Flexible(
          child: Text('Mansi is an AI coach, not a doctor. For pain or medical conditions, consult a professional.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: AppColors.text3)),
        ),
      ]),
    ]);
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.msg, required this.onRetry});
  final _Msg msg;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final mine = msg.role == 'user';
    final maxW = MediaQuery.sizeOf(context).width * 0.8;
    final bubble = GestureDetector(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: msg.content));
        HapticFeedback.mediumImpact();
        toast(context, 'Copied', icon: Icons.copy_rounded);
      },
      child: Container(
        constraints: BoxConstraints(maxWidth: maxW),
        padding: EdgeInsets.all(msg.image != null ? 5 : 0),
        decoration: BoxDecoration(
          gradient: mine ? const LinearGradient(colors: [Color(0xFF7C5CFF), Color(0xFF9B5CFF)]) : null,
          color: mine ? null : AppColors.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: Radius.circular(mine ? 20 : 6),
            bottomRight: Radius.circular(mine ? 6 : 20),
          ),
          boxShadow: mine ? null : AppShadows.soft,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (msg.image != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.memory(msg.image!, height: 180, width: maxW, fit: BoxFit.cover),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
            child: mine
                ? Text(msg.content,
                    style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.45, fontWeight: FontWeight.w500))
                : MiniMarkdown(msg.content),
          ),
        ]),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
        Row(
          mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!mine) ...[const MansiAvatar(size: 28, animate: false), const SizedBox(width: 8)],
            Flexible(child: bubble),
          ],
        ),
        if (msg.failed)
          Tap(
            onTap: onRetry,
            child: const Padding(
              padding: EdgeInsets.only(top: 6, right: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.error_outline_rounded, size: 15, color: AppColors.red),
                SizedBox(width: 4),
                Text('Not sent · Tap to retry',
                    style: TextStyle(fontSize: 12, color: AppColors.red, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
      ]),
    );
  }
}

class _Typing extends StatefulWidget {
  const _Typing();

  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        const MansiAvatar(size: 28),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
              bottomRight: Radius.circular(20),
              bottomLeft: Radius.circular(6),
            ),
            boxShadow: AppShadows.soft,
          ),
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, _) => Row(
              children: List.generate(3, (i) {
                final t = ((_c.value - i * 0.15) % 1.0);
                final lift = t < 0.4 ? (t < 0.2 ? t / 0.2 : (0.4 - t) / 0.2) : 0.0;
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2.5),
                  transform: Matrix4.translationValues(0, -5 * lift, 0),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: Color.lerp(AppColors.text3, AppColors.purple, lift),
                    shape: BoxShape.circle,
                  ),
                );
              }),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.image,
    required this.onRemoveImage,
    required this.onAttach,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final Uint8List? image;
  final VoidCallback onRemoveImage;
  final VoidCallback onAttach;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        boxShadow: [BoxShadow(color: Color(0x101A1B25), blurRadius: 16, offset: Offset(0, -4))],
      ),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (image != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
              child: Stack(clipBehavior: Clip.none, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.memory(image!, width: 76, height: 76, fit: BoxFit.cover),
                ),
                Positioned(
                  right: -8,
                  top: -8,
                  child: Tap(
                    onTap: onRemoveImage,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(color: AppColors.ink, shape: BoxShape.circle),
                      child: const Icon(Icons.close_rounded, size: 15, color: Colors.white),
                    ),
                  ),
                ),
              ]),
            ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final canSend = !sending && (value.text.trim().isNotEmpty || image != null);
              return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                IconButton(
                  tooltip: 'Add photo',
                  onPressed: sending ? null : onAttach,
                  icon: const Icon(Icons.add_photo_alternate_outlined, color: AppColors.purple, size: 26),
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.newline,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                    decoration: InputDecoration(
                      hintText: 'Message Mansi…',
                      filled: true,
                      fillColor: AppColors.surfaceAlt,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      enabledBorder:
                          OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      focusedBorder:
                          OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Tap(
                  onTap: canSend ? onSend : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: canSend ? AppColors.mansiGradient : null,
                      color: canSend ? null : AppColors.line,
                    ),
                    child: sending
                        ? const Padding(
                            padding: EdgeInsets.all(13),
                            child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.text3))
                        : Icon(Icons.arrow_upward_rounded, color: canSend ? Colors.white : AppColors.text3),
                  ),
                ),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}
