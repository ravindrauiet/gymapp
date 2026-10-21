import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:fitkey_core/fitkey_core.dart';
import '../../data/models.dart';
import '../../state/session.dart';

class ChatMessageItem {
  ChatMessageItem({required this.role, required this.content, DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();

  final String role; // 'user' | 'assistant'
  final String content;
  final DateTime timestamp;
}

/// FitKey AI Coach: Interactive fitness, workout & nutrition chatbot
/// powered by ChatGPT (GPT-4o-mini), personalized to user's goals & baselines.
class AiCoachScreen extends StatefulWidget {
  const AiCoachScreen({super.key});

  @override
  State<AiCoachScreen> createState() => _AiCoachScreenState();
}

class _AiCoachScreenState extends State<AiCoachScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessageItem> _messages = [];

  bool _isSending = false;
  UserGoal? _userGoal;

  final List<String> _quickPrompts = [
    '🥗 High protein vegetarian meal ideas',
    '🍗 How to hit 120g protein on a budget',
    '🏋️ Suggest a 4-day hypertrophy workout split',
    '🔥 What is the best calorie deficit for fat loss?',
    '🍌 Best pre-workout food 30 mins before gym',
    '💧 How much water should I drink on workout days?',
  ];

  @override
  void initState() {
    super.initState();
    _loadUserGoal();
    _initWelcomeMessage();
  }

  void _initWelcomeMessage() {
    _messages.add(
      ChatMessageItem(
        role: 'assistant',
        content:
            'Namaste! I\'m your **FitKey AI Coach** 🏋️‍♂️.\n\n'
            'I have direct access to your fitness goals, calorie targets, and workout logs. '
            'Ask me anything about:\n'
            '• Muscle building & strength routines\n'
            '• Indian diet macro swaps (paneer, soya, dal, chicken, eggs)\n'
            '• Fat loss, calorie tracking & plateau breaking\n'
            '• Form tips for squats, bench & deadlifts\n\n'
            'How can I help you crush your goals today?',
      ),
    );
  }

  Future<void> _loadUserGoal() async {
    try {
      final goal = await context.read<Session>().api.goal();
      if (mounted) {
        setState(() {
          _userGoal = goal;
        });
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage([String? presetText]) async {
    final text = (presetText ?? _textController.text).trim();
    if (text.isEmpty || _isSending) return;

    _textController.clear();
    setState(() {
      _messages.add(ChatMessageItem(role: 'user', content: text));
      _isSending = true;
    });
    _scrollToBottom();

    try {
      // Map message history for ChatGPT API
      final payload = _messages.map((m) => {'role': m.role, 'content': m.content}).toList();

      final reply = await context.read<Session>().api.sendChatMessage(payload);

      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessageItem(role: 'assistant', content: reply));
        _isSending = false;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSending = false);
      showSnack(context, errorMessage(e), error: true);
    }
  }

  void _resetConversation() {
    setState(() {
      _messages.clear();
      _initWelcomeMessage();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: FkColors.lime.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.smart_toy, color: FkColors.lime, size: 20),
            ),
            const SizedBox(width: 10),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('FitKey AI Coach', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                Text(
                  'Powered by ChatGPT (GPT-4o)',
                  style: TextStyle(fontSize: 10, color: FkColors.lime),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Clear conversation',
            icon: const Icon(Icons.restart_alt),
            onPressed: _resetConversation,
          ),
        ],
      ),
      body: Column(
        children: [
          // Personalized Goal Header
          if (_userGoal != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: FkColors.surfaceHigh,
              child: Row(
                children: [
                  const Icon(Icons.track_changes, color: FkColors.lime, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Goal: ${_userGoal!.goalLabel.split('(').first.trim()} · Target: ${_userGoal!.dailyCalorieTarget} kcal · ${_userGoal!.dailyProteinG}g Protein',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white70),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Chat message list
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isUser = msg.role == 'user';
                return _buildMessageBubble(msg, isUser);
              },
            ),
          ),

          // Thinking Indicator
          if (_isSending) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: FkColors.lime),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'FitKey AI Coach is writing...',
                    style: TextStyle(fontSize: 12, color: FkColors.lime.withValues(alpha: 0.9), fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
          ],

          // Quick Prompt Suggestion Chips
          SizedBox(
            height: 38,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: _quickPrompts.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, idx) {
                final prompt = _quickPrompts[idx];
                return ActionChip(
                  label: Text(prompt, style: const TextStyle(fontSize: 11)),
                  backgroundColor: FkColors.surface,
                  side: BorderSide(color: FkColors.outline.withValues(alpha: 0.5)),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  onPressed: () => _sendMessage(prompt),
                );
              },
            ),
          ),
          const SizedBox(height: 8),

          // Bottom Input Composer
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              decoration: const BoxDecoration(
                color: FkColors.surface,
                border: Border(top: BorderSide(color: FkColors.outline)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      decoration: InputDecoration(
                        hintText: 'Ask FitKey AI Coach anything...',
                        hintStyle: const TextStyle(fontSize: 13, color: FkColors.textSecondary),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        filled: true,
                        fillColor: const Color(0xFF191D24),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: FkColors.lime,
                      foregroundColor: Colors.black,
                    ),
                    icon: _isSending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                          )
                        : const Icon(Icons.send, size: 20),
                    onPressed: _isSending ? null : () => _sendMessage(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessageItem msg, bool isUser) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: FkColors.lime.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.fitness_center, color: FkColors.lime, size: 16),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isUser ? FkColors.lime.withValues(alpha: 0.15) : FkColors.surface,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
                border: Border.all(
                  color: isUser ? FkColors.lime.withValues(alpha: 0.4) : FkColors.outline,
                ),
              ),
              child: SelectableText(
                msg.content,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: isUser ? Colors.white : const Color(0xFFE5E7EB),
                ),
              ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: const BoxDecoration(
                color: FkColors.surfaceHigh,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.person, color: Colors.white, size: 16),
            ),
          ],
        ],
      ),
    );
  }
}
