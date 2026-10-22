/** Category photos used for the seeded demo venues. */
// Real, category-matched photography (Unsplash licence — free for commercial use, no attribution required).
const unsplash = (id) => `https://images.unsplash.com/photo-${id}?w=1000&q=75&fm=jpg&fit=crop`;
export const CATEGORY_PHOTOS = {
  gym: ['1534438327276-14e5300c3a48', '1540497077202-7c8a3999166f', '1517836357463-d25dfeac3438', '1583454110551-21f2fa2afe61', '1599058917212-d750089bc07e'],
  swimming_pool: ['1530549387789-4c1017266635', '1576013551627-0cc20b96c2a7'],
  sports_club: ['1626224583764-f87db24ac4ea', '1595435934249-5df7ed86e1c0', '1546519638-68e109498ffc'],
  yoga_studio: ['1544367567-0f2fcb009e0b', '1599901860904-17e6ed7083a0', '1518611012118-696072aa579a'],
  mma: ['1517438322307-e67111335449', '1549719386-74dfcbf7dbed', '1599058917212-d750089bc07e'],
  martial_arts: ['1555597673-b21d5c935865', '1517438322307-e67111335449'],
  dance: ['1508700929628-666bc8bd84ea', '1535525153412-5a42439a210d', '1518611012118-696072aa579a'],
};

/** Photos for a venue from its categories, rotated by `offset` so venues sharing a category look different. */
export const photosFor = (categories, offset = 0) => {
  const ids = [...new Set(categories.flatMap((c) => CATEGORY_PHOTOS[c] ?? CATEGORY_PHOTOS.gym))];
  return ids.map((_, i) => unsplash(ids[(i + offset) % ids.length]));
};
