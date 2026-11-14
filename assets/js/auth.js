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
})();
