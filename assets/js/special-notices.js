// Special Notices card (Welcome page and member home page). Requires auth.js first.
// QGPCSpecial.show({ members: true|false })  members=true also shows members-only notices.
(function(){
  var BUCKET='special-notices';
  function today(){return new Intl.DateTimeFormat('en-CA',{timeZone:'America/Chicago',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());}
  window.QGPCSpecial={
    photoUrl:function(path){return QGPC.sb.storage.from(BUCKET).getPublicUrl(path).data.publicUrl;},
    show:function(opts){
      var card=document.getElementById('special-card'),ul=document.getElementById('special-list');
      if(!card||!ul)return;
      var q=QGPC.sb.from('special_notices').select('*').or('show_until.is.null,show_until.gte.'+today()).order('created_at',{ascending:false});
      if(!(opts&&opts.members))q=q.eq('members_only',false);
      q.then(function(r){
        var list=(r&&r.data)||[];
        ul.textContent='';
        if(r.error||!list.length){card.classList.add('hidden');return;}
        list.forEach(function(n){
          var li=document.createElement('li');
          if(n.photo_path){var im=document.createElement('img');im.src=QGPCSpecial.photoUrl(n.photo_path);im.alt=n.photo_alt||'';im.loading='lazy';li.appendChild(im);}
          var d=document.createElement('div');
          var h=document.createElement('h3');h.textContent=n.headline;d.appendChild(h);
          if(n.message){var p=document.createElement('p');p.textContent=n.message;d.appendChild(p);}
          li.appendChild(d);ul.appendChild(li);
        });
        card.classList.remove('hidden');
      });
    }
  };
})();
