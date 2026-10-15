//! Extension host prelude: the JS globals every real extension
//! is written against, built on the thin `host` primitives from
//! [crate::host]. Calling convention, response shapes, and the
//! never-throw `{error}` failure contract mirror the public
//! SpotiFLAC host API (MIT, spotiflacapp/SpotiFLAC-Mobile,
//! `rust_backend/crates/extensions/src/prelude.js`) so community
//! extensions run unmodified. This file is our own implementation
//! of that interface - adapted, not copied - with attribution kept
//! here: interface derived from SpotiFLAC-Mobile (c) its authors,
//! MIT licensed.
//!
//! The Rust side exposes ONE object, `host`, whose functions all
//! take/return JSON strings (never throw). Everything semantic
//! (header-vs-body arg positions, fetch shapes, URLSearchParams,
//! TextEncoder, atob, timers) lives here in JS where it is cheap
//! to match exactly.

/// Evaluate the prelude in `ctx` after `host` is set. Idempotent
/// per context (fresh runtime per call, so always fresh).
pub const PRELUDE: &str = r###"
(function(host) {
"use strict";
function goString(v) {
  if (v === null || v === undefined) return "";
  if (typeof v === "string") return v;
  try { return String(v); } catch (e) { return ""; }
}
// ---------- URL / URLSearchParams (pairs live in JS) ----------
function makeParams(pairs) {
  var store = pairs || [];
  return {
    append: function(k, v) { store.push([goString(k), goString(v)]); },
    delete: function(k) {
      k = goString(k);
      store = store.filter(function(e) { return e[0] !== k; });
    },
    get: function(k) {
      k = goString(k);
      for (var i = 0; i < store.length; i++) {
        if (store[i][0] === k) return store[i][1];
      }
      return null;
    },
    getAll: function(k) {
      k = goString(k);
      var out = [];
      for (var i = 0; i < store.length; i++) {
        if (store[i][0] === k) out.push(store[i][1]);
      }
      return out;
    },
    has: function(k) {
      k = goString(k);
      for (var i = 0; i < store.length; i++) {
        if (store[i][0] === k) return true;
      }
      return false;
    },
    set: function(k, v) {
      k = goString(k); v = goString(v);
      var done = false;
      store = store.filter(function(e) {
        if (e[0] === k) {
          if (done) return false;
          e[1] = v; done = true;
        }
        return true;
      });
      if (!done) store.push([k, v]);
    },
    toString: function() {
      return store.map(function(e) {
        return encodeURIComponent(e[0]) + "=" + encodeURIComponent(e[1]);
      }).join("&");
    }
  };
}
globalThis.URL = function(input, base) {
  if (!(this instanceof URL)) throw new TypeError("URL requires new");
  var p = { href: "", protocol: "", hostname: "", port: "", pathname: "", search: "", hash: "" };
  if (arguments.length) {
    try {
      var r = JSON.parse(host.parseURL(goString(input), base === undefined ? "" : goString(base)));
      if (r && !r.error) p = r;
      else if (r && r.href) p.href = r.href;
    } catch (e) { p.href = goString(input); }
  }
  this.href = p.href; this.protocol = p.protocol; this.hostname = p.hostname;
  this.port = p.port; this.pathname = p.pathname; this.search = p.search;
  this.hash = p.hash;
  var q = (p.search || "").replace(/^\?/, "");
  var pairs = [];
  try { pairs = JSON.parse(host.parseQuery(q)); } catch (e) {}
  this.searchParams = makeParams(pairs);
  this.toString = function() { return this.href; };
};
globalThis.URLSearchParams = function(init) {
  if (!(this instanceof URLSearchParams)) throw new TypeError("URLSearchParams requires new");
  var pairs = [];
  if (typeof init === "string") {
    try { pairs = JSON.parse(host.parseQuery(goString(init).replace(/^\?/, ""))); } catch (e) {}
  } else if (init && typeof init === "object") {
    for (var k in init) {
      if (Object.prototype.hasOwnProperty.call(init, k)) pairs.push([k, goString(init[k])]);
    }
  }
  var p = makeParams(pairs);
  for (var m in p) this[m] = p[m];
};
// ---------- error text (message first: QuickJS stacks are
// frames-only, so stack-first reads as a bare location) ----------
globalThis.__needle_err_text = function(e) {
  // Verification challenges carry their callback URL as fields,
  // not message text: surface them machine-readably so the app
  // can open the browser without another round-trip.
  try {
    if (e && e.needsVerification) {
      var url = e.authUrl || e.auth_url || "";
      return "VERIFY_REQUIRED|" + url;
    }
  } catch (x) {}
  var msg = "";
  try { msg = String((e && e.message) || ""); } catch (x) {}
  var frame = "";
  try {
    var st = String((e && e.stack) || "");
    frame = (st.split("\n")[0] || "").trim();
  } catch (x) {}
  if (!msg) return frame || String(e);
  return frame ? (msg + " [" + frame + "]") : msg;
};
// ---------- registerExtension ----------
globalThis.registerExtension = function(tbl) {
  globalThis.__needle_registry = (tbl === undefined) ? null : tbl;
};
// ---------- storage / credentials ----------
function storageReadJS(cred, key, fallback) {
  try {
    var r = JSON.parse(host.storageRead(!!cred, goString(key)));
    if (r && r.error === undefined) return r.found ? r.value : fallback;
  } catch (e) {}
  return fallback;
}
function storageWriteJS(cred, key, value) {
  try {
    var r = JSON.parse(host.storageWrite(!!cred, goString(key), JSON.stringify(value === undefined ? null : value)));
    return !!(r && r.success);
  } catch (e) { return { success: false, error: goString(e) }; }
}
if (host.storageEnabled) {
  globalThis.storage = {
    get: function(k, fb) { return arguments.length ? storageReadJS(false, k, fb) : undefined; },
    set: function(k, v) { return arguments.length >= 2 ? storageWriteJS(false, k, v) : false; },
    remove: function(k) {
      if (!arguments.length) return false;
      try { return !!JSON.parse(host.storageRemove(false, goString(k))).success; }
      catch (e) { return false; }
    }
  };
  globalThis.credentials = {
    get: function(k, fb) { return arguments.length ? storageReadJS(true, k, fb) : undefined; },
    store: function(k, v) {
      if (arguments.length < 2) return { success: false, error: "key and value are required" };
      return storageWriteJS(true, k, v);
    },
    has: function(k) {
      if (!arguments.length) return false;
      try { return !!JSON.parse(host.storageRead(true, goString(k))).found; }
      catch (e) { return false; }
    },
    remove: function(k) {
      if (!arguments.length) return false;
      try { return !!JSON.parse(host.storageRemove(true, goString(k))).success; }
      catch (e) { return false; }
    }
  };
}
// ---------- cache (storage-backed, "__cache." prefix) ----------
globalThis.cache = {
  has: function(k) { return storageReadJS(false, "__cache." + goString(k), null) !== null; },
  get: function(k) { return storageReadJS(false, "__cache." + goString(k), undefined); },
  set: function(k, v) { return storageWriteJS(false, "__cache." + goString(k), v); },
  delete: function(k) {
    if (!arguments.length) return false;
    try { return !!JSON.parse(host.storageRemove(false, "__cache." + goString(k))).success; }
    catch (e) { return false; }
  },
  keys: function() {
    try {
      var r = JSON.parse(host.storageKeys("__cache."));
      return (r && r.ok) ? r.value : [];
    } catch (e) { return []; }
  },
  size: function() {
    try {
      var r = JSON.parse(host.storageKeys("__cache."));
      return (r && r.ok) ? r.value.length : 0;
    } catch (e) { return 0; }
  }
};
// ---------- http / fetch ----------
function plainHeaders(v) {
  var h = {};
  if (v && typeof v === "object" && !Array.isArray(v)) {
    for (var k in v) {
      if (!Object.prototype.hasOwnProperty.call(v, k)) continue;
      var item = v[k];
      if (typeof item === "string") h[k] = item;
      else if (typeof item === "number" || typeof item === "boolean") h[k] = String(item);
    }
  }
  return h;
}
function callRequest(url, method, body, headers, wantBytes) {
  var r;
  try {
    r = JSON.parse(host.request(goString(url), goString(method), goString(body), JSON.stringify(plainHeaders(headers)), !!wantBytes));
  } catch (e) { return { error: "request failed: " + goString(e) }; }
  return r;
}
function fetchError(err) {
  return { ok: false, status: 0, statusText: "Network Error", error: err,
    text: function() { return ""; }, json: function() { return undefined; } };
}
if (host.networkEnabled) {
  globalThis.http = {
    get: function(u, h) { return callRequest(u, "GET", "", h, false); },
    post: function(u, b, h) {
      return callRequest(u, "POST", (typeof b === "string") ? b : JSON.stringify(b === undefined ? null : b), h, false);
    },
    put: function(u, b, h) {
      return callRequest(u, "PUT", (typeof b === "string") ? b : JSON.stringify(b === undefined ? null : b), h, false);
    },
    patch: function(u, b, h) {
      return callRequest(u, "PATCH", (typeof b === "string") ? b : JSON.stringify(b === undefined ? null : b), h, false);
    },
    delete: function(u, h) { return callRequest(u, "DELETE", "", h, false); },
    request: function(u, o) {
      o = (o && typeof o === "object") ? o : {};
      var m = (typeof o.method === "string") ? o.method : "GET";
      var b = (typeof o.body === "string") ? o.body : (o.body ? JSON.stringify(o.body) : "");
      return callRequest(u, m, b, o.headers, false);
    },
    clearCookies: function() {
      try { return !!host.clearCookies(); } catch (e) { return false; }
    }
  };
  globalThis.fetch = function(u, o) {
    o = (o && typeof o === "object") ? o : {};
    var m = (typeof o.method === "string") ? o.method : "GET";
    var b = (typeof o.body === "string") ? o.body : (o.body ? JSON.stringify(o.body) : "");
    var r = callRequest(u, m, b, o.headers, true);
    if (!r || r.error !== undefined) return fetchError(r && r.error ? r.error : "fetch failed");
    var bytes = r.bytes || [];
    var text;
    r.text = function() {
      if (text === undefined) {
        // The string body always rides the envelope; the byte
        // array exists only under the binary cap (arrayBuffer).
        if (typeof r.body === "string" && r.body !== "") text = r.body;
        else {
          try { text = host.decodeBytes(JSON.stringify(bytes)); }
          catch (e) { text = r.body || ""; }
        }
      }
      return text;
    };
    r.json = function() { try { return JSON.parse(r.text()); } catch (e) { return undefined; } };
    r.arrayBuffer = function() { return new Uint8Array(bytes); };
    r.statusText = r.ok ? "OK" : ("HTTP " + r.status);
    r.url = goString(u);
    return r;
  };
}
// ---------- log / console ----------
function logArgs(args) {
  var out = [];
  for (var i = 0; i < Math.min(args.length, 8); i++) {
    var v = args[i];
    if (v === null || v === undefined) out.push("");
    else if (typeof v === "string") out.push(v.slice(0, 513));
    else {
      try { out.push(JSON.stringify(v).slice(0, 513)); }
      catch (e) { out.push(goString(v).slice(0, 513)); }
    }
  }
  return out;
}
globalThis.log = {};
["debug", "info", "warn", "error"].forEach(function(level) {
  globalThis.log[level] = function() {
    try { host.extensionLog(level.toUpperCase(), logArgs(arguments)); }
    catch (e) {}
  };
});
if (host.managedConsole) {
  globalThis.console = {
    log: function() {
      try { host.extensionLog("", logArgs(arguments)); } catch (e) {}
    }
  };
}
// ---------- matching ----------
globalThis.matching = {
  compareStrings: function(a, b) {
    if (arguments.length < 2) return 0;
    try { return host.compareStrings(goString(a), goString(b)); }
    catch (e) { return 0; }
  },
  compareDuration: function(a, b, t) {
    if (arguments.length < 2) return false;
    try { return !!host.compareDuration(+a, +b, (t === undefined) ? 3000 : +t); }
    catch (e) { return false; }
  },
  normalizeString: function(v) {
    if (!arguments.length) return "";
    try { return host.normalizeMatching(goString(v)); } catch (e) { return ""; }
  }
};
// ---------- gobackend (legacy surface) ----------
if (host.legacyBackend) {
  globalThis.gobackend = {
    sanitizeFilename: function(v) {
      if (!arguments.length) return "";
      try { return host.legacySanitize(goString(v)); } catch (e) { return ""; }
    },
    buildFilename: function(t, m) {
      if (arguments.length < 2) return "";
      try { return host.legacyFilename(goString(t), JSON.stringify(m || {})); }
      catch (e) { return ""; }
    },
    getLocalTime: function() {
      try { return JSON.parse(host.legacyLocalTime()); } catch (e) { return {}; }
    },
    getAudioQuality: function(p) {
      if (!arguments.length) return { error: "file path is required" };
      try { return JSON.parse(host.legacyQuality(goString(p))); }
      catch (e) { return { error: "quality unavailable" }; }
    },
    getLyricsLRC: function() { return { error: "lyrics unavailable" }; },
    checkISRCExists: function(dir, isrc) {
      if (arguments.length < 2) return { error: "outputDir and isrc are required" };
      try { return JSON.parse(host.legacyIsrc(false, goString(dir), goString(isrc), "")); }
      catch (e) { return { error: "isrc check unavailable" }; }
    },
    addToISRCIndex: function(dir, isrc, path) {
      if (arguments.length < 3) return { error: "outputDir, isrc, and filePath are required" };
      try { return JSON.parse(host.legacyIsrc(true, goString(dir), goString(isrc), goString(path))); }
      catch (e) { return { error: "isrc index unavailable" }; }
    }
  };
}
// ---------- utils ----------
globalThis.utils = {
  isDownloadCancelled: function() {
    try { return !!host.downloadCancelled(); } catch (e) { return false; }
  },
  isRequestCancelled: function() {
    try { return !!host.requestCancelled(); } catch (e) { return false; }
  },
  randomUserAgent: function() {
    try { return host.randomUserAgent(); } catch (e) { return "Mozilla/5.0"; }
  },
  appUserAgent: function() {
    try { return host.appUserAgent(); } catch (e) { return "Needle/1.0"; }
  },
  appVersion: function() {
    try { return host.appVersion(); } catch (e) { return "0.1.0"; }
  },
  getResolutionRemainingMs: function() {
    try { return host.resolutionRemaining(); } catch (e) { return 0; }
  },
  base64Encode: function(v) {
    if (!arguments.length) return "";
    try { return host.base64Encode(goString(v)); } catch (e) { return ""; }
  },
  base64Decode: function(v) {
    if (!arguments.length) return "";
    try { return host.base64Decode(goString(v), false); } catch (e) { return ""; }
  },
  md5: function(v) {
    if (!arguments.length) return "";
    try { return host.md5(goString(v)); } catch (e) { return ""; }
  },
  sha256: function(v) {
    if (!arguments.length) return "";
    try { return host.sha256(goString(v)); } catch (e) { return ""; }
  },
  hmacSHA256: function(msg, key) {
    if (arguments.length < 2) return "";
    try { return host.hmacSHA256(goString(msg), goString(key)); } catch (e) { return ""; }
  },
  hmacSHA256Base64: function(msg, key) {
    if (arguments.length < 2) return "";
    try { return host.hmacSHA256Base64(goString(msg), goString(key)); } catch (e) { return ""; }
  },
  hmacSHA1: function(key, message) {
    function toBytes(v) {
      if (typeof v === "string") return JSON.parse(host.encode(goString(v)));
      if (Array.isArray(v)) {
        return v.map(function(n) { return (typeof n === "number") ? (n & 255) : 0; });
      }
      return null;
    }
    var k = toBytes(key), m = toBytes(message);
    if (k === null || m === null) return [];
    try {
      var r = JSON.parse(host.hmacSHA1(JSON.stringify(k), JSON.stringify(m)));
      return (r && r.ok) ? r.value : [];
    } catch (e) { return []; }
  },
  parseJSON: function(v) {
    if (!arguments.length) return undefined;
    try { return JSON.parse(String(v)); } catch (e) { return undefined; }
  },
  stringifyJSON: function(v) {
    if (!arguments.length) return "";
    try { return JSON.stringify(v === undefined ? null : v); } catch (e) { return ""; }
  },
  sleep: function(ms) {
    if (typeof ms !== "number" || !(ms > 0)) return true;
    try { return !!host.sleep(Math.min(Math.trunc(ms), 300000)); }
    catch (e) { return false; }
  }
};
// ---------- atob / btoa / TextEncoder / TextDecoder ----------
globalThis.btoa = function(v) {
  if (!arguments.length) return "";
  try { return host.base64Encode(goString(v)); } catch (e) { return ""; }
};
globalThis.atob = function(v) {
  if (!arguments.length) return "";
  try { return host.base64Decode(goString(v), true); } catch (e) { return ""; }
};
globalThis.TextEncoder = function() {
  this.encoding = "utf-8";
  this.encode = function(v) {
    if (!arguments.length) return [];
    try { return JSON.parse(host.encode(goString(v))); } catch (e) { return []; }
  };
  this.encodeInto = function(v) {
    if (arguments.length < 1) return { read: 0, written: 0 };
    var n = 0;
    try { n = JSON.parse(host.encode(goString(v))).length; } catch (e) {}
    return { read: n, written: n };
  };
};
globalThis.TextDecoder = function(enc) {
  this.encoding = (enc === undefined) ? "utf-8" : goString(enc);
  this.fatal = false; this.ignoreBOM = false;
  this.decode = function(v) {
    if (typeof v === "string") return goString(v);
    var arr = null;
    if (Array.isArray(v)) arr = v;
    else if (typeof Uint8Array !== "undefined" && v instanceof Uint8Array) arr = Array.from(v);
    if (!arr) return "";
    try { return host.decodeBytes(JSON.stringify(arr)); } catch (e) { return ""; }
  };
};
// ---------- file ----------
if (host.filesEnabled) {
  globalThis.__needle_cbs = {};
  globalThis.__needle_cbSeq = 1;
  function fileCallJS(method, args) {
    var required = (method === "copy" || method === "move" || method === "transformPatternedBlocks") ? 2 : 1;
    if (args.length < required) {
      if (method === "exists") return false;
      return { success: false, error: "path is required" };
    }
    try {
      var value = (method === "copy" || method === "move" || method === "transformPatternedBlocks") ? goString(args[1]) : "";
      var options = "{}";
      if (method === "readBytes" && args.length > 1) options = JSON.stringify(args[1] || {});
      if (method === "transformPatternedBlocks") {
        var o = {};
        if (args.length > 2 && args[2] && typeof args[2] === "object") {
          for (var k in args[2]) {
            if (Object.prototype.hasOwnProperty.call(args[2], k) && typeof args[2][k] !== "function") o[k] = args[2][k];
          }
        }
        if (args.length > 3 && typeof args[3] === "function") {
          var cbId = globalThis.__needle_cbSeq++;
          globalThis.__needle_cbs[cbId] = args[3];
          o.__cb = cbId;
        }
        options = JSON.stringify(o);
      }
      var out = host.fileCall(method, goString(args[0]), value, options);
      if (method === "exists") return out === "true";
      return JSON.parse(out);
    } catch (e) { return { success: false, error: goString(e) }; }
  }
  globalThis.file = {};
    ["exists", "delete", "read", "readBytes", "write", "writeBytes", "copy", "move", "getSize", "transformPatternedBlocks"].forEach(function(m) {
      globalThis.file[m] = function() { return fileCallJS(m, arguments); };
    });
  globalThis.file.download = function(url, path, options) {
    if (arguments.length < 2) return { success: false, error: "URL and output path are required" };
    var opts = (options && typeof options === "object") ? options : {};
    var cbId = 0;
    if (typeof opts.onProgress === "function") {
      cbId = globalThis.__needle_cbSeq++;
      globalThis.__needle_cbs[cbId] = opts.onProgress;
    }
    try {
      var out = JSON.parse(host.downloadCall(goString(url), goString(path),
        JSON.stringify({ headers: plainHeaders(opts.headers), cb: cbId, chunked: !!opts.chunked })));
      if (cbId) delete globalThis.__needle_cbs[cbId];
      return out;
    } catch (e) {
      if (cbId) delete globalThis.__needle_cbs[cbId];
      return { success: false, error: goString(e) };
    }
  };
  globalThis.file.downloadSegments = function(segments, path, options) {
    function fail(t, e) { return { success: false, error: e, error_type: t, attempts: 0 }; }
    if (arguments.length < 2) return fail("invalid_request", "segments and output path are required");
    if (!Array.isArray(segments) || !segments.length) return fail("invalid_request", "segments must be a non-empty array");
    var specs = [];
    for (var i = 0; i < segments.length; i++) {
      var item = segments[i], url = "", headers = {};
      if (typeof item === "string") url = item;
      else if (item && typeof item === "object") {
        url = (typeof item.url === "string") ? item.url : "";
        headers = plainHeaders(item.headers);
      } else return fail("invalid_request", "segment " + i + " must be a URL string or object");
      specs.push({ url: url, headers: headers });
    }
    try {
      return JSON.parse(host.downloadSegmentsCall(JSON.stringify(specs), goString(path), "{}"));
    } catch (e) { return fail("download_error", goString(e)); }
  };
}
// ---------- session / auth (gated by host flags) ----------
if (host.sessionEnabled) {
  globalThis.session = {
    status: function() {
      try { return JSON.parse(host.sessionCall("status", "[]")); }
      catch (e) { return { authenticated: false }; }
    },
    clear: function() {
      try { return JSON.parse(host.sessionCall("clear", "[]")); }
      catch (e) { return { success: false }; }
    },
    completeGrant: function(g) {
      try { return JSON.parse(host.sessionCall("completeGrant", JSON.stringify(g === undefined ? [] : [goString(g)]))); }
      catch (e) { return { success: false, error: goString(e) }; }
    },
    signedFetch: function(method, path, body, headers) {
      if (arguments.length < 2) return { ok: false, error: "method and path are required" };
      try {
        return JSON.parse(host.sessionCall("signedFetch", JSON.stringify([
          goString(method), goString(path),
          (typeof body === "string") ? body : (body ? JSON.stringify(body) : ""),
          plainHeaders(headers)])));
      } catch (e) { return { ok: false, error: goString(e) }; }
    }
  };
}
if (host.authEnabled) {
  globalThis.auth = {
    openAuthUrl: function() { return { success: false, error: "oauth unavailable" }; },
    getAuthCode: function() { return undefined; },
    setAuthCode: function() { return { success: false, error: "oauth unavailable" }; },
    clearAuth: function() { try { return JSON.parse(host.authCall("clearAuth", "[]")); } catch (e) { return { success: true }; } },
    isAuthenticated: function() { return false; },
    getTokens: function() {
      return { access_token: "", refresh_token: "", is_authenticated: false, expires_at: 0, is_expired: true };
    },
    generatePKCE: function() { return {}; },
    getPKCE: function() { return {}; },
    startOAuthWithPKCE: function() { return { success: false, error: "oauth unavailable" }; },
    exchangeCodeWithPKCE: function() { return { success: false, error: "oauth unavailable" }; }
  };
}
// ---------- timers (driver-pumped) ----------
globalThis.__needle_timerSeq = 1;
globalThis.__needle_timers = [];
globalThis.setTimeout = function(fn, ms) {
  var id = globalThis.__needle_timerSeq++;
  globalThis.__needle_timers.push({ id: id, at: Date.now() + Math.max(0, +ms || 0), fn: fn });
  return id;
};
globalThis.clearTimeout = function(id) {
  globalThis.__needle_timers = globalThis.__needle_timers.filter(function(t) { return t.id !== id; });
};
globalThis.__needle_fireDue = function() {
  var now = Date.now(), due = [], rest = [];
  globalThis.__needle_timers.forEach(function(t) { ((now >= t.at) ? due : rest).push(t); });
  globalThis.__needle_timers = rest;
  due.forEach(function(t) {
    try { if (typeof t.fn === "function") t.fn(); } catch (e) {}
  });
  return due.length;
};
globalThis.__needle_nextDueIn = function() {
  var now = Date.now(), best = -1;
  globalThis.__needle_timers.forEach(function(t) {
    var d = t.at - now;
    if (best < 0 || d < best) best = d;
  });
  return best;
};
globalThis.AbortController = function() {
  var signal = { aborted: false };
  this.signal = signal;
  this.abort = function() { signal.aborted = true; };
};
}
)(globalThis.__needle_host);
"###;
