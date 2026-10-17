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
  const location = clean(match[1]).replace(/\b(?:and|but|because|today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday|at)\b.*$/i, '').trim();
  return location.length >= 3 ? location : undefined;
}

export function candidate(input) {
  if (typeof input !== 'string') return [];
  const text = clean(input.slice(0, 5000));
  if (text.length < 8) return [];

  const out = [];
  const time = text.match(/\b(?:at\s+)?(1[0-2]|0?[1-9])(?::([0-5]\d))?\s?(AM|PM)\b/i)?.[0]?.replace(/^at\s+/i, '');
  const location = locationFrom(text);

  // Meetings, appointments, deadlines and date/time commitments become events.
  if (/\b(meet(?:ing)?|appointment|doctor|interview|flight|deadline|due date|reservation|call with|scheduled|tomorrow|tonight|today|next week|this (?:morning|afternoon|evening)|on (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b/i.test(text)) {
    out.push({
      type: 'EVENT',
      title: /\b(deadline|due date)\b/i.test(text) ? 'Deadline' : /\b(doctor|appointment)\b/i.test(text) ? 'Appointment' : 'Upcoming event',
      description: text,
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

  // Capture useful context from both first-person and third-person messages: relationships,
  // work, education, goals, preferences, dietary restrictions, dates and contact details.
  // Every result remains a suggestion that the user must explicitly approve.
  const personalPatterns = [
    {pattern:/\b(?:my birthday is|my anniversary is|born on|birthday falls on)\b/i,title:'Birthday or anniversary'},
    {pattern:/\b(?:my (?:wife|husband|partner|fiancee?|friend|brother|sister|mother|father|son|daughter|child|colleague|manager|client|customer)'?s? name is|my name is)\b/i,title:'Person or relationship'},
    {pattern:/\b(?:i live in|i am based in|i'm based in|my home is in|i moved to)\b/i,title:'Home or location'},
    {pattern:/\b(?:i work at|i work in|i work as|my job is|my business is|i run|i own|i am employed by)\b/i,title:'Work or business'},
    {pattern:/\b(?:i study|i am studying|i'm studying|my course is|i attend|my school is|my university is)\b/i,title:'Education or studies'},
    {pattern:/\b(?:my goal is|i plan to|i want to|i hope to|i am working toward|i'm working toward)\b/i,title:'Goal or plan'},
    {pattern:/\b(?:my favorite|my favourite|i prefer|i like|i love|i dislike|i hate)\b/i,title:'Likes and preferences'},
    {pattern:/\b(?:i am allergic to|i'm allergic to|i cannot eat|i can't eat|i avoid)\b/i,title:'Dietary or sensitivity detail'},
    {pattern:/\b(?:my email is|email me at|my phone number is|you can call me at|reach me at)\b/i,title:'Contact detail'},
    {pattern:/\b(?:remember that|keep in mind|please remember|important to me|i need you to know)\b/i,title:'Important personal context'},
    {pattern:/\b(?:he is|she is|they are|his birthday is|her birthday is|their birthday is|he works at|she works at|they work at|he prefers|she prefers|they prefer|he studies|she studies|they study|his goal is|her goal is|their goal is|his number is|her number is|his email is|her email is)\b/i,title:'Other person's details'},
  ];
  for (const personalMatch of personalPatterns.filter(item => item.pattern.test(text))) {
    out.push({type:'NOTE',title:personalMatch.title,description:text,...(location?{location}:{})});
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
