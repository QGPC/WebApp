// Shared sign-in helpers. Requires supabase-js and config.js to be loaded first.
(function(){
  var C = window.QGPC_CONFIG;
  var sb = window.supabase.createClient(C.SUPABASE_URL, C.SUPABASE_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });
  // Site root, correct both on qgpc.github.io/WebApp/ and on a custom domain.
  function siteRoot(){ return location.href.replace(/[^\/]*([?#].*)?$/, ''); }
  window.QGPC = {
    sb: sb,
    signIn: function(email, password, keep){
      return sb.auth.signInWithPassword({ email: email.trim(), password: password });
    },
    signOut: function(){ return sb.auth.signOut(); },
    sendReset: function(email){
      return sb.auth.resetPasswordForEmail(email.trim(), { redirectTo: siteRoot() + 'set-password.html' });
    },
    requestFirstSignin: function(email){
      return sb.functions.invoke('request-signin-link', { body: { email: email.trim() } });
    },
    setPassword: function(pw){ return sb.auth.updateUser({ password: pw }); },
    session: function(){ return sb.auth.getSession().then(function(r){ return r.data.session; }); },
    friendly: function(err){
      if(!err) return '';
      var m = (err.message||'').toLowerCase();
      if(m.indexOf('invalid login')>-1) return 'That email and password do not match. Please try again, or use "Forgot password?".';
      if(m.indexOf('rate')>-1) return 'Too many tries. Please wait a few minutes and try again.';
      return 'Something went wrong. Please try again.';
    }
  };

  // While a Superuser restores a backup, everyone else is sent to the "being restored" page.
  // Superusers are never blocked. Call with the roles the person really holds.
  window.QGPC.maintenanceGate = function(held){
    if (held && held.indexOf('superuser') > -1) return Promise.resolve(false);
    return sb.from('site_config').select('maintenance').limit(1).then(function(r){
      var on = !!(r && r.data && r.data[0] && r.data[0].maintenance === true);
      if (on) location.replace('maintenance.html');
      return on;
    }, function(){ return false; });
  };

  // Every "home" link (the logo, the Home button, "Back to Home") goes to the member home when
  // someone is signed in and to the public welcome page when not.
  function fixHomeLinks(){
    sb.auth.getSession().then(function(r){
      var to = (r.data && r.data.session) ? 'home.html' : 'index.html';
      var list = document.querySelectorAll('a.brand, a.homelink, a.backlink, a.pwlink, #back a');
      for(var i=0;i<list.length;i++){
        var a = list[i], isHome = a.classList.contains('brand') || a.classList.contains('homelink');
        if(!isHome){
          var t = (a.textContent||'').replace(/\s+/g,' ').trim();
          if(!/^Back to (Home|the Guild home page)/i.test(t)) continue;
        }
        a.setAttribute('href', to);
      }
    });
  }
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded', fixHomeLinks); else fixHomeLinks();
  // ---- Banner color and pattern (set on the Site Appearance page) ----
  // The saved choice is kept in this browser too, so the banner is right at once on the next page.
  var AP_KEY = 'qgpc_appearance';
  var AP_DEFAULT = { color: '#017DB0', texture: 'quilt', pattern: 'cobalt', strength: 6, fabric_url: null };
  var AP_PAT = { cobalt: '#0157AE', cream: '#F7F5F0', ink: '#1F2433' };
  function apRgb(h){ var n = parseInt(h.slice(1), 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; }
  function apLum(h){ var c = apRgb(h).map(function(v){ v /= 255; return v <= .03928 ? v / 12.92 : Math.pow((v + .055) / 1.055, 2.4); }); return .2126 * c[0] + .7152 * c[1] + .0722 * c[2]; }
  function apBanner(cfg){
    cfg = Object.assign({}, AP_DEFAULT, cfg || {});
    var k = cfg.strength / 6, pc = AP_PAT[cfg.pattern] || AP_PAT.cobalt;
    function rgba(h, a){ var c = apRgb(h); return 'rgba(' + c[0] + ',' + c[1] + ',' + c[2] + ',' + Math.min(1, a * k).toFixed(2) + ')'; }
    var img = 'none', size = 'auto', pos = '0 0';
    if (cfg.texture === 'quilt') {
      img = 'linear-gradient(135deg,rgba(255,255,255,' + (.10 * k).toFixed(2) + ') 25%,transparent 25%),linear-gradient(225deg,rgba(255,255,255,' + (.10 * k).toFixed(2) + ') 25%,transparent 25%),linear-gradient(45deg,' + rgba(pc, .55) + ' 25%,transparent 25%),linear-gradient(315deg,rgba(255,255,255,' + (.06 * k).toFixed(2) + ') 25%,transparent 25%)';
      size = '64px 64px'; pos = '0 0,0 32px,32px -32px,-32px 0';
    } else if (cfg.texture === 'stripes') {
      img = 'repeating-linear-gradient(45deg,' + rgba(pc, .35) + ' 0 14px,transparent 14px 28px)';
    } else if (cfg.texture === 'checker') {
      img = 'linear-gradient(45deg,' + rgba(pc, .35) + ' 25%,transparent 25%,transparent 75%,' + rgba(pc, .35) + ' 75%),linear-gradient(45deg,' + rgba(pc, .35) + ' 25%,transparent 25%,transparent 75%,' + rgba(pc, .35) + ' 75%)';
      size = '48px 48px'; pos = '0 0,24px 24px';
    } else if (cfg.texture === 'fabric') {
      if (cfg.fabric_url) {
        var cc = apRgb(cfg.color), veil = 'rgba(' + cc[0] + ',' + cc[1] + ',' + cc[2] + ',' + Math.max(.25, Math.min(.85, 1 - cfg.strength / 12)).toFixed(2) + ')';
        img = 'linear-gradient(' + veil + ',' + veil + '),url("' + cfg.fabric_url + '")'; size = 'auto,220px';
      } else {
        img = 'repeating-linear-gradient(0deg,' + rgba(pc, .18) + ' 0 2px,transparent 2px 6px),repeating-linear-gradient(90deg,' + rgba(pc, .18) + ' 0 2px,transparent 2px 6px),radial-gradient(circle at 30% 40%,' + rgba(pc, .30) + ' 0 18px,transparent 19px)';
        size = 'auto,auto,72px 72px';
      }
    }
    return { color: cfg.color, image: img, size: size, pos: pos };
  }
  function apApply(cfg){
    var b = apBanner(cfg), st = document.getElementById('qgpc-appearance');
    if (!st) { st = document.createElement('style'); st.id = 'qgpc-appearance'; document.head.appendChild(st); }
    st.textContent = '.hst{background-color:' + b.color + ';background-image:' + b.image + ';background-size:' + b.size + ';background-position:' + b.pos + '}@media print{.hst{background:none!important}}';
  }
  function apFromRow(r){
    return { color: r.color, texture: r.texture, pattern: r.pattern, strength: r.strength,
      fabric_url: r.fabric_path ? sb.storage.from('site-appearance').getPublicUrl(r.fabric_path).data.publicUrl : null };
  }
  window.QGPC.appearance = { DEFAULT: AP_DEFAULT, PATTERNS: AP_PAT, banner: apBanner, apply: apApply, fromRow: apFromRow, lum: apLum, remember: function(cfg){ try { localStorage.setItem(AP_KEY, JSON.stringify(cfg)); } catch (e) {} } };
  try { var apc = JSON.parse(localStorage.getItem(AP_KEY) || 'null'); if (apc) apApply(apc); } catch (e) {}
  sb.from('site_appearance').select('*').limit(1).then(function(r){
    var row = r && r.data && r.data[0]; if (!row) return;
    var cfg = apFromRow(row); apApply(cfg); window.QGPC.appearance.remember(cfg);
  });
  // ---- Guild contact details and Facebook link (set on the Site Appearance page) ----
  var GC_KEY = 'qgpc_guild_contact';
  function gcApply(g){
    if (!g) return;
    var run = function(){
      // Footer address line
      var line = [g.street, [g.city, [g.state, g.zip].filter(Boolean).join(' ')].filter(Boolean).join(', ')].filter(Boolean).join(' · ');
      var foots = document.querySelectorAll('.site-foot');
      for (var i = 0; i < foots.length; i++) {
        var f = foots[i], spans = f.querySelectorAll('span'), sp = null;
        for (var j = 0; j < spans.length; j++) {
          if (spans[j].getAttribute('data-gc-addr') || (spans[j].textContent || '').indexOf('[Mailing address]') > -1) { sp = spans[j]; break; }
        }
        if (!sp) continue;
        sp.setAttribute('data-gc-addr', '1');
        if (line) sp.textContent = line;
        var old = f.querySelector('[data-gc-row]'); if (old) old.parentNode.removeChild(old);
        var more = [];
        if (g.email) { var a = document.createElement('a'); a.href = 'mailto:' + g.email; a.textContent = g.email; more.push(a); }
        if (g.phone) { var p = document.createElement('a'); p.href = 'tel:' + g.phone.replace(/[^0-9+]/g, ''); p.textContent = g.phone; more.push(p); }
        if (more.length) {
          var row = document.createElement('div'); row.setAttribute('data-gc-row', '1'); row.style.cssText = 'display:flex;flex-wrap:wrap;gap:4px 18px;margin-top:4px';
          more.forEach(function(x){ x.style.cssText = 'color:#fff;font-weight:600;text-decoration:underline;text-underline-offset:3px'; row.appendChild(x); });
          sp.parentNode.insertBefore(row, sp.nextSibling);
          var nx = row.nextSibling; if (nx && nx.nodeName === 'BR') nx.parentNode.removeChild(nx);
        }
      }
      // Header Facebook link
      var oldfb = document.getElementById('qgpc-fb'); if (oldfb && oldfb.getAttribute('href') !== g.facebook_url) { oldfb.parentNode.removeChild(oldfb); oldfb = null; }
      if (!g.facebook_url && oldfb) oldfb.parentNode.removeChild(oldfb);
      if (g.facebook_url && !oldfb) {
        var h = document.querySelector('.head-actions');
        if (h) {
          var fb = document.createElement('a'); fb.id = 'qgpc-fb'; fb.href = g.facebook_url; fb.target = '_blank'; fb.rel = 'noopener';
          fb.setAttribute('aria-label', 'Find us on Facebook (opens in a new tab)');
          fb.style.cssText = 'min-height:44px;padding:0 8px;display:inline-flex;align-items:center;gap:6px;font-weight:600;text-decoration:none;color:#0157AE';
          fb.innerHTML = '<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M13.5 21v-7.5H16l.5-3h-3V8.6c0-.9.3-1.5 1.6-1.5h1.5V4.4c-.3 0-1.2-.1-2.2-.1-2.2 0-3.7 1.3-3.7 3.8v2.4H8v3h2.7V21z"/></svg><span>Find us on Facebook</span>';
          h.insertBefore(fb, h.firstChild);
        }
      }
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run); else run();
  }
  window.QGPC.guildContact = { apply: gcApply, remember: function(g){ try { localStorage.setItem(GC_KEY, JSON.stringify(g)); } catch (e) {} } };
  try { var gcc = JSON.parse(localStorage.getItem(GC_KEY) || 'null'); if (gcc) gcApply(gcc); } catch (e) {}
  sb.from('guild_contact').select('*').limit(1).then(function(r){
    var row = r && r.data && r.data[0]; if (!row) return;
    window.QGPC.guildContact.remember(row); gcApply(row);
  });
})();
