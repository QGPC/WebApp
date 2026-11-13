// Shared page start for signed-in pages. Requires auth.js first.
// QGPCShell.start({ need: function(ctx){ return true/false } }, function(ctx){ ... })
// ctx = { session, member, roles (as acting), held (really held), acting, has(key), isAdmin, isSuper, full }
(function(){
  var $=function(i){return document.getElementById(i)};
  window.QGPCShell={
    start:function(opts,ready){
      var out=$('out'); if(out)out.addEventListener('click',function(){QGPC.signOut().then(function(){location.href='index.html';});});
      QGPC.session().then(function(s){
        if(!s){location.href='index.html';return;}
        return Promise.all([
          QGPC.sb.from('members_with_status').select('*').eq('auth_user_id',s.user.id).limit(1),
          QGPC.sb.from('roles').select('role_key,label')
        ]).then(function(res){
          var r=res[0];
          if(r.error||!r.data||!r.data.length){location.href='home.html';return;}
          var m=r.data[0],lab={};(res[1].data||[]).forEach(function(x){lab[x.role_key]=x.label;});
          return QGPC.sb.from('member_roles').select('role_key').eq('member_id',m.id).then(function(rr){
            var held=(rr.data||[]).map(function(x){return x.role_key;});
            // "Acting as" (chosen on the member home page, kept for this browser tab only):
            // the page behaves as if the person holds only that role, or none for "Member".
            // This changes what pages show and open; database rules always follow the roles really held.
            var pick=null;try{pick=sessionStorage.getItem('qgpc_acting');}catch(e){}
            if(pick&&pick!=='member'&&held.indexOf(pick)<0)pick=null;
            if(!held.length)pick=null;
            var roles=pick?(pick==='member'?[]:[pick]):held;
            var has=function(k){return roles.indexOf(k)>-1;};
            var ctx={session:s,member:m,roles:roles,held:held,acting:pick,has:has,isAdmin:has('superuser')||has('administrator'),isSuper:has('superuser'),
              full:has('superuser')||has('administrator')||m.status==='active'||m.status==='grace'};
            if($('who-name'))$('who-name').textContent=m.first_name+' '+m.last_name;
            if($('avatar'))$('avatar').textContent=((m.first_name||'?').charAt(0)+(m.last_name||'').charAt(0)).toUpperCase();
            if($('who-role'))$('who-role').textContent=pick?'Acting as '+(pick==='member'?'Member':(lab[pick]||pick)):(roles.length?roles.map(function(k){return lab[k]||k;}).join(', '):'Member');
            if(opts&&opts.need&&!opts.need(ctx)){location.href='home.html';return;}
            ready(ctx);
          });
        });
      });
    }
  };
})();
