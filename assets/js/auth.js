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
})();
