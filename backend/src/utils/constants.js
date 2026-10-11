export const VENUE_CATEGORIES = [
  { id: 'gym', label: 'Gym' },
  { id: 'swimming_pool', label: 'Swimming Pool' },
  { id: 'sports_club', label: 'Sports Club' },
  { id: 'yoga_studio', label: 'Yoga Studio' },
  { id: 'mma', label: 'MMA' },
  { id: 'martial_arts', label: 'Martial Arts' },
  { id: 'dance', label: 'Dance' },
];
export const VENUE_CATEGORY_IDS = VENUE_CATEGORIES.map((c) => c.id);

export const VIDEO_CATEGORIES = [
  { id: 'gym', label: 'Gym' },
  { id: 'yoga', label: 'Yoga' },
  { id: 'dance', label: 'Dance / Zumba' },
  { id: 'boxing', label: 'Boxing' },
  { id: 'martial_arts', label: 'Judo / Karate' },
];
export const VIDEO_CATEGORY_IDS = VIDEO_CATEGORIES.map((c) => c.id);

export const AMENITIES = ['locker', 'shower', 'parking', 'ac', 'wifi', 'changing_room', 'drinking_water', 'cafe', 'steam_sauna'];

export const ACTIVITY_TYPES = ['workout', 'running', 'cycling', 'swimming', 'yoga', 'sports', 'other'];

export const WEEKDAYS = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
