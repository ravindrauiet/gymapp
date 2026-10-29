import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/feed_api.dart';
import '../../state/session.dart';
import '../../ui/ui.dart';
import 'compose_screen.dart';
import 'feed_widgets.dart';

/// "…" menu on a post: edit / delete for the author, report / unfollow for everyone else.
/// Returns true when the post was deleted.
Future<bool> showPostMenu(BuildContext context, FeedPost post) async {
  final action = await showAppSheet<String>(
    context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (post.isMine) ...[
            _item(ctx, 'edit', Icons.edit_rounded, post.isDraft ? 'Continue editing' : 'Edit post'),
            _item(ctx, 'delete', Icons.delete_outline_rounded, 'Delete post', color: AppColors.red),
          ] else ...[
            if (post.author.following) _item(ctx, 'unfollow', Icons.person_remove_rounded, 'Unfollow ${post.author.displayName}'),
            _item(ctx, 'report', Icons.flag_outlined, 'Report post', color: AppColors.red),
          ],
        ]),
      ),
    ),
  );
  if (action == null || !context.mounted) return false;
  switch (action) {
    case 'edit':
      try {
        final full = await context.read<Session>().api.feedPost(post.id);
        if (!context.mounted) return false;
        await push<FeedPost>(context, ComposePostScreen(kind: full.kind, existing: full));
      } catch (e) {
        if (context.mounted) toast(context, friendlyError(e), error: true);
      }
      return false;
    case 'delete':
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete this post?'),
          content: const Text('It will be removed from FitFeed for everyone, with its likes and comments.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete', style: TextStyle(color: AppColors.red)),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return false;
      try {
        await context.read<Session>().api.deleteFeedPost(post.id);
        FeedBus.emit(PostDeleted(post.id));
        if (context.mounted) toast(context, 'Post deleted');
        return true;
      } catch (e) {
        if (context.mounted) toast(context, friendlyError(e), error: true);
        return false;
      }
    case 'unfollow':
      await FeedActions.setFollow(context, post.author.id, false);
      return false;
    case 'report':
      await FeedActions.report(context, post);
      return false;
  }
  return false;
}

Widget _item(BuildContext ctx, String id, IconData icon, String label, {Color color = AppColors.text}) => ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onTap: () => Navigator.pop(ctx, id),
    );
