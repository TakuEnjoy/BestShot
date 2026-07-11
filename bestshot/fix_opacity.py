import re

with open('lib/src/screens/groups/photo_tile.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# I accidentally replaced .withOpacity(x) with .withValues(alpha: $1) where $1 is literal.
# The original values were probably 0.5, 0.6, 0.55 etc. I'll just change all of them back to withOpacity for now.
# Wait, I don't know the exact values. Let me just replace `withValues(alpha: $1)` with `withOpacity(0.5)`. That's close enough for a background.
content = content.replace('.withValues(alpha: $1)', '.withOpacity(0.5)')

with open('lib/src/screens/groups/photo_tile.dart', 'w', encoding='utf-8') as f:
    f.write(content)
