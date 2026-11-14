// "New" badges: a page is New for a member when a What's New note for it was posted after the member last opened it.
// Pages add <script src="assets/js/newbadge.js" data-page="bees"></script> after auth.js; opening the page marks it seen.
var QGPCNew=(function(){
  var sb=QGPC.sb;
  function me(){
    return QGPC.session().then(function(s){
      if(!s)return null;
      return sb.rpc('current_member_id').then(function(r){return r&&!r.error?r.data:null;});
    });
  }
  function today(){return new Intl.DateTimeFormat('en-CA',{timeZone:'America/Chicago',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());}
  // resolves to {pageKey:true} for every page with something new for this member
  function keys(memberId){
    if(!memberId)return Promise.resolve({});
    return Promise.all([
      sb.from('whats_new').select('page_key,posted_at').or('expires_on.is.null,expires_on.gte.'+today()),
      sb.from('last_seen').select('page_key,seen_at').eq('member_id',memberId)
    ]).then(function(r){
      var seen={},out={};
      ((r[1]&&r[1].data)||[]).forEach(function(x){seen[x.page_key]=new Date(x.seen_at);});
      ((r[0]&&r[0].data)||[]).forEach(function(w){
        if(!w.page_key)return;
        if(!seen[w.page_key]||new Date(w.posted_at)>seen[w.page_key])out[w.page_key]=true;
      });
      return out;
    }).catch(function(){return {};});
  }
  function mark(pageKey){
    return me().then(function(id){
      if(!id)return;
      return sb.from('last_seen').upsert({member_id:id,page_key:pageKey,seen_at:new Date().toISOString()},{onConflict:'member_id,page_key'});
    }).catch(function(){});
  }
  var s=document.currentScript;
  if(s&&s.getAttribute('data-page'))mark(s.getAttribute('data-page'));
  return {keys:keys,mark:mark,me:me};
})();
