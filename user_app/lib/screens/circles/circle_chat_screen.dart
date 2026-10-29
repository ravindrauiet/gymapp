import 'dart:async';

import 'package:fitkey_core/fitkey_core.dart' show resolveMediaUrl;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart' show XFile;

import '../../data/circles_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import '_voice_path.dart' if (dart.library.io) '_voice_path_io.dart';
import 'circles_common.dart';

/// Circle group chat: text + voice notes, refreshed by polling (like buddy chat).
class CircleChatScreen extends StatefulWidget {
  const CircleChatScreen({super.key, required this.circle});
  final CircleSummary circle;

  @override
  State<CircleChatScreen> createState() => _CircleChatScreenState();
}

class _CircleChatScreenState extends State<CircleChatScreen> {
  final _messages = <CircleMessage>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timer? _poll;
  bool _loading = true;
  bool _fetching = false;
  bool _sending = false;
  Object? _loadError;

  AudioRecorder? _recorder;
  bool _recording = false;
  DateTime? _recordStart;
  Timer? _recordTick;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInput);
    _fetch();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _fetch());
  }

  void _onInput() => setState(() {});

  @override
  void dispose() {
    _poll?.cancel();
    _recordTick?.cancel();
    _recorder?.dispose();
    _input.removeListener(_onInput);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    if (_fetching || !mounted) return;
    _fetching = true;
    try {
      final after = _messages.isEmpty ? null : _messages.last.rawCreatedAt;
      final fresh = await context.read<Session>().api.circleMessages(widget.circle.id, after: after);
      if (!mounted) return;
      final known = _messages.map((m) => m.id).toSet();
      final added = fresh.where((m) => !known.contains(m.id)).toList();
      if (added.isNotEmpty || _loading || _loadError != null) {
        setState(() {
          _messages.addAll(added);
          _loading = false;
          _loadError = null;
        });
      }
    } catch (e) {
      if (mounted && _loading) {
        setState(() {
          _loading = false;
          _loadError = e;
        });
      }
    } finally {
      _fetching = false;
    }
  }

  void _add(CircleMessage m) {
    setState(() {
      if (!_messages.any((x) => x.id == m.id)) _messages.add(m);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  Future<void> _sendText() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    _input.clear();
    setState(() => _sending = true);
    try {
      final m = await context.read<Session>().api.sendCircleMessage(widget.circle.id, body: text);
      if (mounted) _add(m);
    } catch (e) {
      if (!mounted) return;
      if (_input.text.isEmpty) _input.text = text;
      toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _startRecording() async {
    final p = CirclesPrefs.instance;
    if (kIsWeb) {
      toast(context, p.t('voiceWeb'));
      return;
    }
    final rec = _recorder ??= AudioRecorder();
    try {
      if (!await rec.hasPermission()) {
        if (mounted) toast(context, p.t('micDenied'), error: true);
        return;
      }
      final path = await voiceNotePath();
      if (path == null) return;
      await rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, numChannels: 1), path: path);
      if (!mounted) return;
      setState(() {
        _recording = true;
        _recordStart = DateTime.now();
      });
      _recordTick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {});
        // Hard stop at 2 minutes to stay well under the upload limit.
        if (DateTime.now().difference(_recordStart!).inSeconds >= 120) _stopRecording(send: true);
      });
    } catch (e) {
      if (mounted) toast(context, p.t('micDenied'), error: true);
    }
  }

  Future<void> _stopRecording({required bool send}) async {
    _recordTick?.cancel();
    final rec = _recorder;
    if (rec == null || !_recording) return;
    final seconds = DateTime.now().difference(_recordStart ?? DateTime.now()).inSeconds;
    setState(() => _recording = false);
    final path = await rec.stop();
    if (!send || path == null || seconds < 1 || !mounted) return;
    setState(() => _sending = true);
    final api = context.read<Session>().api;
    try {
      final bytes = await XFile(path).readAsBytes();
      final url = await api.uploadVoiceNote(bytes);
      final m = await api.sendCircleMessage(widget.circle.id, audioUrl: url, audioSeconds: seconds.clamp(1, 600));
      if (mounted) _add(m);
    } catch (e) {
      if (mounted) toast(context, friendlyError(e), error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CirclesShell(child: Builder(builder: (context) {
      final p = circlesOf(context);
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.circle.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(p.t('members', {'n': widget.circle.memberCount}),
                style: const TextStyle(fontSize: 12, color: AppColors.text2, fontWeight: FontWeight.w500)),
          ]),
          actions: const [CirclesA11yToggles(), SizedBox(width: 12)],
        ),
        body: Column(children: [
          Expanded(child: _body(p)),
          _composer(p),
        ]),
      );
    }));
  }

  Widget _body(CirclesPrefs p) {
    if (_loading) return const SkeletonList(count: 6, itemHeight: 56);
    if (_loadError != null) {
      return ErrorView(
        error: _loadError!,
        onRetry: () {
          setState(() {
            _loading = true;
            _loadError = null;
          });
          _fetch();
        },
      );
    }
    if (_messages.isEmpty) {
      return EmptyView(icon: Icons.forum_rounded, title: p.t('noMessages'), message: p.t('noMessagesMsg'), color: AppColors.teal);
    }
    final items = _messages.reversed.toList();
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final m = items[i];
        final showName = !m.mine && (i == items.length - 1 || items[i + 1].userId != m.userId);
        return _Bubble(message: m, showName: showName);
      },
    );
  }

  Widget _composer(CirclesPrefs p) {
    final hasText = _input.text.trim().isNotEmpty;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        boxShadow: [BoxShadow(color: Color(0x141A1B25), blurRadius: 20, offset: Offset(0, -4))],
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: SafeArea(
        top: false,
        child: _recording
            ? Row(children: [
                IconButton(
                  tooltip: p.t('cancel'),
                  onPressed: () => _stopRecording(send: false),
                  icon: const Icon(Icons.delete_outline_rounded, color: AppColors.red),
                ),
                const Icon(Icons.fiber_manual_record_rounded, color: AppColors.red, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${_fmtSecs(DateTime.now().difference(_recordStart!).inSeconds)} · ${p.t('recording')}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                _RoundButton(icon: Icons.send_rounded, color: AppColors.primary, onTap: () => _stopRecording(send: true)),
              ])
            : Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(hintText: p.t('typeMessage')),
                    onSubmitted: (_) => _sendText(),
                  ),
                ),
                const SizedBox(width: 8),
                if (_sending)
                  const SizedBox(width: 52, height: 52, child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)))
                else if (hasText)
                  _RoundButton(icon: Icons.send_rounded, color: AppColors.primary, onTap: _sendText)
                else
                  Tooltip(
                    message: kIsWeb ? p.t('voiceWeb') : p.t('holdToRecord'),
                    child: _RoundButton(
                      icon: Icons.mic_rounded,
                      color: kIsWeb ? AppColors.text3 : AppColors.teal,
                      onTap: _startRecording,
                    ),
                  ),
              ]),
      ),
    );
  }
}

String _fmtSecs(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.color, required this.onTap});
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tap(
        onTap: onTap,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 26),
        ),
      );
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.showName});
  final CircleMessage message;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final time = TimeOfDay.fromDateTime(m.createdAt).format(context);
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      decoration: BoxDecoration(
        color: m.mine ? AppColors.primarySoft : AppColors.surface,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(m.mine ? 18 : 4),
          bottomRight: Radius.circular(m.mine ? 4 : 18),
        ),
        boxShadow: AppShadows.soft,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        if (showName)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(m.userName ?? 'Member',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: AppColors.teal)),
          ),
        if (m.audioUrl != null) _VoicePlayer(url: m.audioUrl!, seconds: m.audioSeconds),
        if (m.body != null) Text(m.body!, style: const TextStyle(fontSize: 15, height: 1.35)),
        Align(
          alignment: Alignment.bottomRight,
          child: Text(time, style: const TextStyle(fontSize: 10.5, color: AppColors.text3)),
        ),
      ]),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: m.mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!m.mine) ...[
            Opacity(opacity: showName ? 1 : 0, child: PersonAvatar(name: m.userName ?? 'M', photoUrl: m.avatarUrl, size: 30)),
            const SizedBox(width: 6),
          ],
          Flexible(child: bubble),
        ],
      ),
    );
  }
}

class _VoicePlayer extends StatefulWidget {
  const _VoicePlayer({required this.url, this.seconds});
  final String url;
  final int? seconds;

  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<_VoicePlayer> {
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _posSub;
  bool _playing = false;
  bool _loading = false;
  Duration _pos = Duration.zero;

  @override
  void dispose() {
    _stateSub?.cancel();
    _posSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final url = resolveMediaUrl(widget.url);
    if (url == null) return;
    var player = _player;
    try {
      if (player == null) {
        player = _player = AudioPlayer();
        _stateSub = player.playerStateStream.listen((s) {
          if (!mounted) return;
          final done = s.processingState == ProcessingState.completed;
          setState(() {
            _playing = s.playing && !done;
            _loading = s.processingState == ProcessingState.loading || s.processingState == ProcessingState.buffering;
          });
          if (done) {
            player!.pause();
            player.seek(Duration.zero);
          }
        });
        _posSub = player.positionStream.listen((d) {
          if (mounted) setState(() => _pos = d);
        });
        setState(() => _loading = true);
        await player.setUrl(url);
      }
      if (player.playing) {
        await player.pause();
      } else {
        await player.play();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
        toast(context, 'Could not play this voice note', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _player?.duration ?? Duration(seconds: widget.seconds ?? 0);
    final progress = total.inMilliseconds == 0 ? 0.0 : (_pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    return SizedBox(
      width: 210,
      child: Row(children: [
        Tap(
          onTap: _toggle,
          child: Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(color: AppColors.teal, shape: BoxShape.circle),
            child: _loading
                ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white, size: 28),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 5,
                backgroundColor: AppColors.teal.withValues(alpha: 0.18),
                color: AppColors.teal,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _fmtSecs((_playing || _pos > Duration.zero ? _pos : total).inSeconds),
              style: const TextStyle(fontSize: 11.5, color: AppColors.text2),
            ),
          ]),
        ),
      ]),
    );
  }
}
