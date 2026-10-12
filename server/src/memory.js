// Turn clear, actionable or personal details into user-reviewable Memory Card suggestions.
// This intentionally uses transparent local heuristics: suggestions are never saved automatically.
const TYPES = new Set(['EVENT', 'PAYMENT', 'PLACE', 'TASK', 'NOTE']);

function clean(value) {
  return value.replace(/\s+/g, ' ').trim().replace(/[.!?]+$/, '');
}

function locationFrom(text) {
  // Prefer explicit place phrases and stop before dates/times so the location
  // doesn't accidentally absorb the rest of the sentence.
  const match = text.match(/\b(?:at|in|near|based in|located in|live in|work at|work in)\s+(?:the\s+)?([A-Za-z][A-Za-z0-9'-]*(?:\s+[A-Za-z][A-Za-z0-9'-]*){0,3})/i);
  if (!match) return undefined;
  const location = clean(match[1]).replace(/\b(?:today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday|at)\b.*$/i, '').trim();
  return location.length >= 3 ? location : undefined;
}

export function candidate(input) {
  if (typeof input !== 'string') return [];
  const text = clean(input.slice(0, 5000));
  if (text.length < 8) return [];

  const out = [];
  const time = text.match(/\b(?:at\s+)?(1[0-2]|0?[1-9])(?::([0-5]\d))?\s?(AM|PM)\b/i)?.[0]?.replace(/^at\s+/i, '');
  const date = text.match(/\b(?:today|tonight|tomorrow|this\s+(?:morning|afternoon|evening|week)|next\s+week|(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)(?:\s+\d{1,2}(?:st|nd|rd|th)?)?)\b/i)?.[0];
  const location = locationFrom(text);

  // Meetings, appointments, deadlines and date/time commitments become events.
  if (/\b(meet(?:ing)?|appointment|doctor|interview|flight|deadline|due date|reservation|call with|scheduled|tomorrow|tonight|today|next week|this (?:morning|afternoon|evening)|on (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b/i.test(text)) {
    out.push({
      type: 'EVENT',
      title: /\b(deadline|due date)\b/i.test(text) ? 'Deadline' : /\b(doctor|appointment)\b/i.test(text) ? 'Appointment' : 'Upcoming event',
      description: text,
      ...(date ? { date: date.toLowerCase() } : {}),
      ...(time ? { time } : {}),
      ...(location ? { location } : {}),
    });
  }

  // Explicit reminders and obligations become tasks, not generic notes.
  const task = text.match(/\b(?:remember to|don't forget to|do not forget to|remind me to|need to|have to|must|todo|to-do|task is to)\s+(.+?)(?:[.!?]|$)/i);
  if (task) {
    const description = clean(task[1]);
    if (description.length >= 4) out.push({ type: 'TASK', title: 'Reminder', description });
  }

  // Save money details only when the message includes a monetary signal.
  const money = text.match(/\b(?:KES|KSh|shillings?)\s*[0-9][0-9,]*(?:\.\d{1,2})?\b|\b(?:pay|paid|owe|owed|costs?|rent|bill|payment)\b[^.!?]{0,70}\b[0-9][0-9,]*(?:\.\d{1,2})?\b/i);
  if (money) out.push({ type: 'PAYMENT', title: 'Payment or amount', description: text });

  // Stable personal details are useful memory candidates, but remain suggestions
  // that the user must explicitly approve.
  const personalFact = /\b(?:my birthday is|my anniversary is|i live in|i work at|i work in|i am based in|i'm based in|my job is|i work as|my goal is|my favorite|my favourite|i prefer|i am allergic to|i'm allergic to|my child's name is|my dog's name is|my cat's name is)\b/i.test(text);
  if (personalFact) {
    const title = /birthday|anniversary/i.test(text) ? 'Important date'
      : /live in|based in/i.test(text) ? 'Home or location'
      : /work|job/i.test(text) ? 'Work detail'
      : /prefer|favorite|favourite/i.test(text) ? 'Preference'
      : /allergic/i.test(text) ? 'Important personal detail'
      : 'Personal detail';
    out.push({ type: 'NOTE', title, description: text, ...(location ? { location } : {}) });
  }

  // A place alone is suggested only when the message clearly says it matters.
  if (location && /\b(?:visit|go to|meet at|lives? in|based in|located in|work at|work in|office is in|home is in)\b/i.test(text) && !out.some(item => item.type === 'PLACE')) {
    out.push({ type: 'PLACE', title: 'Place to remember', description: text, location });
  }

  // Deduplicate category/title pairs and reject malformed records. Never turn
  // every ordinary chat message into a low-value "Important note" suggestion.
  const seen = new Set();
  return out.filter(item => {
    if (!TYPES.has(item.type) || !item.title || !item.description) return false;
    const key = item.type + ':' + item.title;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  }).slice(0, 3);
}
