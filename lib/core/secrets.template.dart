// Copy to secrets.local.dart and fill in. secrets.local.dart is gitignored
// and never committed - the app degrades to local-only metadata without it.
const lastFmApiKey = 'PASTE_KEY_HERE';
// Free personal key from https://fanart.tv/get-an-api-key - feeds true
// artist wordmarks (HD ClearLogo). Empty = display-font fallback names.
const fanartApiKey = 'PASTE_KEY_HERE';
// Free key from https://www.theaudiodb.com (signup -> API section) -
// second wordmark source (strLogo). Empty = lane stays quiet.
const audioDbApiKey = 'PASTE_KEY_HERE';
// Free key from https://getsongbpm.com/api (free tier: 3,000 req/hr,
// backlink to getsongbpm.com required in the store listing) - feeds
// tempo + key_of + open_key for harmonic ordering. Empty = lane stays
// quiet; embedded tags still resolve where present.
const getSongBpmApiKey = 'PASTE_KEY_HERE';
