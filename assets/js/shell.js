// Shared page start for signed-in pages. Requires auth.js first.
// QGPCShell.start({ need: function(ctx){ return true/false } }, function(ctx){ ... })
// ctx = { session, member, roles, has(key), isAdmin, isSuper, full }
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
            var roles=(rr.data||[]).map(function(x){return x.role_key;});
            var has=function(k){return roles.indexOf(k)>-1;};
            var ctx={session:s,member:m,roles:roles,has:has,isAdmin:has('superuser')||has('administrator'),isSuper:has('superuser'),
              full:has('superuser')||has('administrator')||m.status==='active'||m.status==='grace'};
            if($('who-name'))$('who-name').textContent=m.first_name+' '+m.last_name;
            if($('avatar'))$('avatar').textContent=((m.first_name||'?').charAt(0)+(m.last_name||'').charAt(0)).toUpperCase();
            if($('who-role'))$('who-role').textContent=roles.length?roles.map(function(k){return lab[k]||k;}).join(', '):'Member';
            if(opts&&opts.need&&!opts.need(ctx)){location.href='home.html';return;}
            ready(ctx);
          });
        });
      });
    }
  };
})();
