// Turns a raw listing title like "Las Vegas Aces at Golden State Valkyries 04.10.2026"
// into structured data: date, league, season, phase, home/away team.
// Team lists are plain data — add aliases here if a team gets mis-sorted, then hit
// "Reclassify" in the UI (or POST /api/reclassify).

const NBA = {
  'Atlanta Hawks': [],
  'Boston Celtics': [],
  'Brooklyn Nets': [],
  'Charlotte Hornets': [],
  'Chicago Bulls': [],
  'Cleveland Cavaliers': ['Cleveland Cavs'],
  'Dallas Mavericks': ['Dallas Mavs'],
  'Denver Nuggets': [],
  'Detroit Pistons': [],
  'Golden State Warriors': ['GS Warriors', 'Golden State Warriors Blue', 'Golden State Warriors Gold'],
  'Houston Rockets': [],
  'Indiana Pacers': [],
  'LA Clippers': ['Los Angeles Clippers', 'L.A. Clippers'],
  'Los Angeles Lakers': ['LA Lakers', 'L.A. Lakers'],
  'Memphis Grizzlies': [],
  'Miami Heat': [],
  'Milwaukee Bucks': [],
  'Minnesota Timberwolves': ['Minnesota Wolves'],
  'New Orleans Pelicans': [],
  'New York Knicks': ['NY Knicks'],
  'Oklahoma City Thunder': ['OKC Thunder', 'Oklahoma Thunder'],
  'Orlando Magic': [],
  'Philadelphia 76ers': ['Philadelphia Sixers', 'Philly 76ers'],
  'Phoenix Suns': [],
  'Portland Trail Blazers': ['Portland Blazers', 'Portland Trailblazers'],
  'Sacramento Kings': [],
  'San Antonio Spurs': ['SA Spurs'],
  'Toronto Raptors': [],
  'Utah Jazz': [],
  'Washington Wizards': [],
};

const WNBA = {
  'Atlanta Dream': [],
  'Chicago Sky': [],
  'Connecticut Sun': [],
  'Dallas Wings': [],
  'Golden State Valkyries': ['GS Valkyries'],
  'Indiana Fever': [],
  'Las Vegas Aces': ['LV Aces'],
  'Los Angeles Sparks': ['LA Sparks'],
  'Minnesota Lynx': [],
  'New York Liberty': ['NY Liberty'],
  'Phoenix Mercury': [],
  'Portland Fire': [],
  'Seattle Storm': [],
  'Toronto Tempo': [],
  'Washington Mystics': [],
};

const EUROLEAGUE = {
  'Anadolu Efes Istanbul': ['Anadolu Istanbul', 'Anadolu Efes', 'Efes Istanbul'],
  'AS Monaco': ['Monaco'],
  'ASVEL Villeurbanne': ['LDLC ASVEL Villeurbanne', 'ASVEL'],
  'Baskonia Vitoria-Gasteiz': ['Baskonia', 'Kosner Baskonia Vitoria-Gasteiz'],
  'Crvena Zvezda Belgrade': ['Crvena Zvezda', 'Red Star Belgrade', 'Crvena Zvezda Meridianbet Belgrade'],
  'Dubai Basketball': [],
  'FC Barcelona': ['Barcelona'],
  'FC Bayern Munich': ['Bayern Munich'],
  'Fenerbahce Istanbul': ['Fenerbahce', 'Fenerbahce BEKO Istanbul', 'Fenerbahce Beko'],
  'Hapoel Tel Aviv': ['Hapoel IBI Tel Aviv'],
  'Maccabi Tel Aviv': ['Maccabi Playtika Tel Aviv', 'Maccabi Rapyd Tel Aviv'],
  'Olimpia Milan': ['Armani Milan', 'EA7 Emporio Armani Milan', 'Olimpia Milano'],
  'Olympiacos Piraeus': ['Olympiacos'],
  'Panathinaikos Athens': ['Panathinaikos', 'Panathinaikos AKTOR Athens'],
  'Paris Basketball': [],
  'Partizan Belgrade': ['Partizan', 'Partizan Bet Belgrade', 'Partizan Mozzart Bet Belgrade'],
  'Real Madrid': [],
  'Valencia Basket': ['Valencia'],
  'Virtus Bologna': ['Virtus Segafredo Bologna', 'Virtus Olidata Bologna'],
  'Zalgiris Kaunas': ['Zalgiris'],
  'Besiktas Istanbul': ['Besiktas'],
  'ALBA Berlin': [],
};

const NATIONAL = [
  'USA', 'France', 'Germany', 'Spain', 'China', 'Australia', 'Hungary', 'Italy', 'Korea',
  'Belgium', 'Puerto Rico', 'Nigeria', 'Brazil', 'Serbia', 'Greece', 'Canada', 'Japan',
  'Lithuania', 'Slovenia', 'Turkey', 'Argentina', 'Latvia', 'Montenegro', 'Croatia', 'Poland',
  'Finland', 'Georgia', 'Czech Republic', 'Czechia', 'Israel', 'Mexico', 'Dominican Republic',
  'New Zealand', 'Philippines', 'Iran', 'Jordan', 'Lebanon', 'South Sudan', 'Angola', 'Senegal',
  'Egypt', 'Cape Verde', 'Venezuela', 'Colombia', 'Ukraine', 'Great Britain', 'Sweden',
  'Bosnia and Herzegovina', 'Estonia', 'Iceland', 'Netherlands', 'Portugal', 'Mali',
];
const NATIONAL_ALIASES = { 'United States': 'USA', 'Team USA': 'USA', 'South Korea': 'Korea' };

// Full names seen on the site, used to expand short forms ("Kansas" -> "Kansas Jayhawks").
const NCAA_KNOWN = [
  'Michigan Wolverines', 'Arizona Wildcats', 'Duke Blue Devils', 'Purdue Boilermakers',
  'Illinois Fighting Illini', 'UConn Huskies', 'Michigan State Spartans', 'UCLA Bruins',
  'Kansas Jayhawks', 'Iowa State Cyclones', "St. John's Red Storm", 'Nebraska Cornhuskers',
  'Houston Cougars', 'Ohio State Buckeyes', 'Florida Gators', 'Arkansas Razorbacks',
  'Kentucky Wildcats', 'Texas Longhorns', 'Vanderbilt Commodores', 'TCU Horned Frogs',
  'Wisconsin Badgers', 'Maryland Terrapins', 'Indiana Hoosiers', 'Alabama Crimson Tide',
  'Gonzaga Bulldogs', 'Virginia Cavaliers', 'Arizona State Sun Devils', 'Oregon Ducks',
  'North Carolina Tar Heels', 'Tennessee Volunteers', 'Texas Tech Red Raiders', 'SMU Mustangs',
  'NC State Wolfpack', 'Xavier Musketeers', 'Louisville Cardinals', 'Seton Hall Pirates',
  'Rutgers Scarlet Knights', 'Baylor Bears', 'Villanova Wildcats', 'Iowa Hawkeyes',
  'Saint Louis Billikens', 'Miami Hurricanes', 'UCF Knights', 'Santa Clara Broncos',
  'Georgia Bulldogs', 'Howard Bison', 'Marquette Golden Eagles', 'Clemson Tigers',
  'Notre Dame Fighting Irish', 'Northwestern Wildcats', 'Penn State Nittany Lions',
  'Minnesota Golden Gophers', 'Cincinnati Bearcats', 'Washington Huskies', 'Georgetown Hoyas',
  'USC Trojans', 'Kansas State Wildcats', 'Oregon State Beavers', 'Syracuse Orange',
  'Creighton Bluejays', 'Butler Bulldogs', 'BYU Cougars', 'Utah Utes', 'Siena Saints',
  'North Dakota State Bison', 'West Virginia Mountaineers', 'DePaul Blue Demons',
];

const EVENT_RE = /all[\s-]?star|rising stars|skills (competition|challenge)|slam dunk|three[\s-]point|3[\s-]point contest|draft/i;

const CYRILLIC = { 'А': 'A', 'В': 'B', 'Е': 'E', 'К': 'K', 'М': 'M', 'Н': 'H', 'О': 'O', 'Р': 'P', 'С': 'C', 'Т': 'T', 'Х': 'X', 'а': 'a', 'е': 'e', 'о': 'o', 'р': 'p', 'с': 'c', 'у': 'y', 'х': 'x', 'і': 'i' };

const norm = (s) => s
  .replace(/[А-яі]/g, (c) => CYRILLIC[c] ?? c)
  .normalize('NFKD').replace(/[̀-ͯ]/g, '')
  .toLowerCase().replace(/&/g, ' and ').replace(/[^a-z0-9]+/g, ' ').trim();

// alias (normalized) -> { name, league }
const INDEX = new Map();
function addLeague(dict, league) {
  for (const [name, aliases] of Object.entries(dict)) {
    for (const a of [name, ...aliases]) INDEX.set(norm(a), { name, league });
  }
}
addLeague(NBA, 'NBA');
addLeague(WNBA, 'WNBA');
addLeague(EUROLEAGUE, 'EuroLeague');
for (const n of NATIONAL) INDEX.set(norm(n), { name: n, league: 'International' });
for (const [a, n] of Object.entries(NATIONAL_ALIASES)) INDEX.set(norm(a), { name: n, league: 'International' });
const INDEX_KEYS = [...INDEX.keys()];

function levenshtein(a, b) {
  if (Math.abs(a.length - b.length) > 2) return 99;
  const prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let diag = prev[0];
    prev[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const tmp = prev[j];
      prev[j] = Math.min(prev[j] + 1, prev[j - 1] + 1, diag + (a[i - 1] === b[j - 1] ? 0 : 1));
      diag = tmp;
    }
  }
  return prev[b.length];
}

export function decodeEntities(s) {
  return s
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n));
}

/** Resolve a raw team string to { name, league|null }. */
export function resolveTeam(raw) {
  let s = raw.replace(/^(?:No\.\s*)?#?\d{1,2}\s+(?=\D)/, '').replace(/\s+/g, ' ').trim();
  const n = norm(s);
  if (!n) return null;
  if (INDEX.has(n)) return INDEX.get(n);
  // Extra trailing words, e.g. "Golden State Warriors Blue", "Chicago Bulls Jul"
  for (const k of INDEX_KEYS) {
    if (k.length >= 8 && n.startsWith(k + ' ') && n.split(' ').length - k.split(' ').length <= 1) return INDEX.get(k);
  }
  // Typos, e.g. "Connecticuy Sun", "Atalanta Dream"
  if (n.length >= 8) {
    let best = null, bestD = 3;
    for (const k of INDEX_KEYS) {
      if (k.length < 8) continue;
      const d = levenshtein(n, k);
      if (d < bestD) { best = k; bestD = d; }
    }
    if (best && bestD <= 2) return INDEX.get(best);
  }
  // College: expand "Michigan St" / short names to a known full name
  s = s.replace(/(\S)\s+St(?=\s|$)/, '$1 State');
  const ns = norm(s);
  const full = NCAA_KNOWN.find((f) => norm(f) === ns)
    ?? (() => {
      const c = NCAA_KNOWN.filter((f) => {
        const nf = norm(f);
        return nf.startsWith(ns + ' ') && !/^(state|st)\b/.test(nf.slice(ns.length + 1));
      });
      return c.length === 1 ? c[0] : null;
    })();
  return { name: full ?? s, league: null };
}

/** dd.mm.yy(yy) -> YYYY-MM-DD. `hintDate` (a neighbouring game's date) fills in a broken year. */
export function parseDate(title, hintDate = null) {
  const m = title.match(/(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})(?!\d)/);
  if (m) {
    let [, d, mo, y] = m;
    if (y.length === 2) y = '20' + y;
    return `${y}-${mo.padStart(2, '0')}-${d.padStart(2, '0')}`;
  }
  const p = title.match(/(\d{1,2})\.(\d{1,2})\.\d{0,3}\s*$/);
  if (p && hintDate) return `${hintDate.slice(0, 4)}-${p[2].padStart(2, '0')}-${p[1].padStart(2, '0')}`;
  return null;
}

const md = (date) => {
  const [, m, d] = date.split('-').map(Number);
  return m * 100 + d; // e.g. April 18 -> 418
};

function seasonFor(league, date) {
  if (!date) return null;
  const y = +date.slice(0, 4), m = +date.slice(5, 7);
  if (league === 'WNBA' || league === 'International') return String(y);
  const start = m >= 7 ? y : y - 1;
  return `${start}-${String((start + 1) % 100).padStart(2, '0')}`;
}

function phaseFor(league, date, title, isEvent) {
  if (isEvent) return 'All-Star & Events';
  if (!date) return null;
  const x = md(date);
  switch (league) {
    case 'NBA':
      if (x >= 701 && x <= 731) return 'Summer League';
      if (x >= 1001 && x <= 1020) return 'Preseason';
      if (x >= 414 && x <= 417) return 'Play-In';
      if (x >= 418 && x <= 531) return 'Playoffs';
      if (x >= 601 && x <= 630) return 'Finals';
      return 'Regular Season';
    case 'WNBA':
      if (x < 514) return 'Preseason';
      if (x >= 913) return 'Playoffs';
      return 'Regular Season';
    case 'EuroLeague':
      if (x >= 801 && x <= 930) return 'Preseason';
      if (x >= 414 && x <= 514) return 'Playoffs';
      if (x >= 515 && x <= 630) return 'Final Four';
      return 'Regular Season';
    case 'NCAA':
      if (x >= 317 && x <= 415) return 'NCAA Tournament';
      return 'Regular Season';
    case 'International':
      return /olympic/i.test(title) ? 'Olympics' : 'International';
    default:
      return null;
  }
}

/** Classify one listing title. */
export function classify(rawTitle, hintDate = null) {
  const title = decodeEntities(rawTitle).replace(/\s+/g, ' ').trim();
  const date = parseDate(title, hintDate);
  let body = title.replace(/\s*\d{1,2}\.\d{1,2}\.\d{0,4}\s*$/, '').trim();
  let competition = null;
  const oly = body.match(/^Olympic Basketball (Men's|Women's)\s+/i);
  if (oly) { competition = 'Olympics'; body = body.slice(oly[0].length); }

  const isEvent = EVENT_RE.test(body);
  let home = null, away = null, league = null;

  if (!isEvent) {
    const at = body.split(/\s+(?:at|@)\s+/i);
    const vs = body.split(/\s+(?:vs?\.?)\s*(?=[A-Z0-9])|\s+[-–]\s*|\s*[-–]\s+/);
    let a, b, neutralOrder;
    if (at.length === 2) { [a, b] = at; neutralOrder = false; }
    else if (vs.length === 2) { [a, b] = vs; neutralOrder = true; }
    if (a && b) {
      const ta = resolveTeam(a), tb = resolveTeam(b);
      if (ta && tb) {
        // "A at B" -> B is home. "A vs B" / "A - B" -> A listed first as home.
        if (neutralOrder) { home = ta; away = tb; } else { home = tb; away = ta; }
        const leagues = [ta.league, tb.league];
        const pro = leagues.find((l) => l && l !== 'International');
        if (ta.league && ta.league === tb.league) league = ta.league;
        else if (pro) league = pro; // e.g. Brazil vs Indiana Fever (exhibition)
        else if (leagues.includes('International')) league = 'International';
        else league = 'NCAA'; // neither side is a known pro/national team
      }
    }
  } else {
    league = /wnba/i.test(body) ? 'WNBA' : 'NBA';
  }
  if (competition === 'Olympics') league = 'International';
  if (!league) league = 'Other';

  let phase = phaseFor(league, date, title, isEvent);
  const mixed = home && away && home.league !== away.league && home.league && away.league;
  if (mixed && league !== 'International') phase = 'Exhibition';

  return {
    title,
    game_date: date,
    league,
    season: seasonFor(league, date),
    phase,
    home_team: home?.name ?? null,
    away_team: away?.name ?? null,
    is_event: isEvent ? 1 : 0,
  };
}

/**
 * Identity of a game across sources and listings: date + both teams (order-independent, so
 * "A at B" and "B vs A" match), or date + title for events without teams.
 */
export function matchKey({ game_date, home_team, away_team, title }) {
  if (!game_date) return null;
  if (home_team && away_team) return `${game_date}|${[home_team, away_team].map(norm).sort().join('|')}`;
  const t = norm(String(title ?? '').replace(/\s*\d{1,2}\.\d{1,2}\.\d{0,4}\s*$/, ''));
  return t ? `${game_date}|${t}` : null;
}
