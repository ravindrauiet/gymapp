-- "AI Arena" is now "ProveIt" (BRD §1): rename it in stored event text and notifications already sent.
UPDATE contests SET title = replace(title, 'AI Arena', 'ProveIt'), description = replace(description, 'AI Arena', 'ProveIt')
  WHERE title LIKE '%AI Arena%' OR description LIKE '%AI Arena%';
UPDATE contests SET description = replace(description, 'in the ProveIt.', 'on ProveIt.') WHERE description LIKE '%in the ProveIt.%';
UPDATE notifications SET title = replace(title, 'AI Arena', 'ProveIt'), body = replace(body, 'AI Arena', 'ProveIt')
  WHERE title LIKE '%AI Arena%' OR body LIKE '%AI Arena%';
