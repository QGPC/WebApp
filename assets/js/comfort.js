// Shared helpers for the Comfort Quilts pages. Load after auth.js (needs QGPC).
(function(){
  var BUCKET='comfort-patterns';
  var C=window.QGPCComfort={
    BUCKET:BUCKET,
    el:function(tag,cls,txt){var e=document.createElement(tag);if(cls)e.className=cls;if(txt!=null)e.textContent=txt;return e;},
    // 'Oct 6, 2026' in Guild time, from a date (YYYY-MM-DD) or a timestamp
    nice:function(d){
      if(!d)return '';
      var dt=(typeof d==='string'&&d.length===10)?new Date(d+'T12:00:00'):new Date(d);
      return new Intl.DateTimeFormat('en-US',{timeZone:'America/Chicago',month:'short',day:'numeric',year:'numeric'}).format(dt);
    },
    today:function(){return new Intl.DateTimeFormat('en-CA',{timeZone:'America/Chicago',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());},
    uuid:function(){return (window.crypto&&crypto.randomUUID)?crypto.randomUUID():(Date.now().toString(16)+Math.random().toString(16).slice(2));},
    safeUrl:function(u){return /^https?:\/\//i.test(u||'')?u:null;},
    // Who is looking at a public page: signed in? a full member? may they manage Comfort Quilts?
    // Follows the "Acting as" choice from the member home page, like QGPCShell does.
    who:function(){
      var none={signedIn:false,full:false,manage:false,roles:[]};
      return QGPC.session().then(function(s){
        if(!s)return none;
        return QGPC.sb.from('members_with_status').select('*').eq('auth_user_id',s.user.id).limit(1).then(function(r){
          var m=r.data&&r.data[0];if(!m)return {signedIn:true,full:false,manage:false,roles:[]};
          return QGPC.sb.from('member_roles').select('role_key').eq('member_id',m.id).then(function(rr){
            var held=(rr.data||[]).map(function(x){return x.role_key;});
            var pick=null;try{pick=sessionStorage.getItem('qgpc_acting');}catch(e){}
            if(pick&&pick!=='member'&&held.indexOf(pick)<0)pick=null;
            if(!held.length)pick=null;
            var roles=pick?(pick==='member'?[]:[pick]):held;
            var has=function(k){return roles.indexOf(k)>-1;};
            var adm=has('superuser')||has('administrator');
            return {signedIn:true,member:m,roles:roles,full:adm||m.status==='active'||m.status==='grace',manage:adm||has('comfort_quilts_chair')};
          });
        });
      });
    },
    // Signed links for files in the private bucket: returns {path: url}
    signed:function(paths){
      paths=(paths||[]).filter(Boolean);
      if(!paths.length)return Promise.resolve({});
      return QGPC.sb.storage.from(BUCKET).createSignedUrls(paths,3600).then(function(r){
        var m={};(r.data||[]).forEach(function(x){if(x&&x.signedUrl&&x.path)m[x.path]=x.signedUrl;});return m;
      });
    },
    // Shrink a photo in the browser: longest side max px, JPEG, white behind transparent PNGs
    shrink:function(file,max){
      return new Promise(function(res,rej){
        var img=new Image(),u=URL.createObjectURL(file);
        img.onload=function(){
          var s=Math.min(1,max/Math.max(img.width,img.height));
          var c=document.createElement('canvas');c.width=Math.max(1,Math.round(img.width*s));c.height=Math.max(1,Math.round(img.height*s));
          var g=c.getContext('2d');g.fillStyle='#fff';g.fillRect(0,0,c.width,c.height);g.drawImage(img,0,0,c.width,c.height);
          URL.revokeObjectURL(u);
          c.toBlob(function(b){b?res(b):rej(new Error('Could not shrink the photo.'));},'image/jpeg',0.85);
        };
        img.onerror=function(){URL.revokeObjectURL(u);rej(new Error('That file does not look like a photo.'));};
        img.src=u;
      });
    },
    safeName:function(n){return String(n||'file').replace(/[^A-Za-z0-9._-]+/g,'-').replace(/^-+|-+$/g,'').slice(0,60)||'file';},
    // 'abcd-1234-name.pdf' -> 'name.pdf' (the first 36 characters are the unique id)
    shownName:function(path){var f=String(path||'').split('/').pop();return f.replace(/^[0-9a-f-]{36}-/,'');},
    plural:function(n,one,many){return n+' '+(n===1?one:many||one+'s');}
  };
})();
