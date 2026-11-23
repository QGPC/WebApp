// Menu tiles for the pages that open from the Home tiles (the same tiles, in the same order, with the same
// role rules, "New" pills and waiting-count badges as the Home page header). Requires auth.js first.
// A page opts in with: <script src="assets/js/tilebar.js"></script> after auth.js. It adds the tile bar under the
// header, then loads navmenu.js so phones get the Menu button. The tile lists below are a copy of home.html's:
// when a tile is added or renamed on Home, change it here too.
// For a signed-in person it also puts My Profile and Messages to the right of the tiles, as on Home. Sign out stays in the
// top row at the far right (after the Facebook and Home links); the old name block there is removed.
(function(){
  var head=document.querySelector('.site-head');if(!head)return;
  var wrap=head.querySelector('.wrap'),top=head.querySelector('.head-top');if(!wrap||!top||document.getElementById('tilebar'))return;
  var $=function(i){return document.getElementById(i)};
  var T=function(f){return 'assets/tiles/'+f+'.svg'};
  var cur=location.pathname.split('/').pop()||'index.html';
  var TIPS={"Programs & Workshops": "Get details about our programs and workshops planned for each month.", "Comfort Quilts": "Our outreach program. Learn about the organizations we support and get easy patterns.", "Bees": "Small groups that meet to sew together. Find one to join.", "Retreats": "See our retreats by year: dates, place, cost and how to sign up.", "Our Community": "Sunshine & Shadows and other ways we care for each other.", "About our Guild": "Learn the purpose and history of our Guild.", "Newsletters": "Read the current newsletter and past issues.", "Block of the Month": "Sew along with the Guild. See the quilt and open each month\u2019s block pattern.", "BOM Chair": "Add the quilt photo, name and description, and a PDF for each month.", "Comfort Quilts Chair": "Update the Comfort Quilts page.", "Bees Chair": "Update the list of bees.", "Workshop Registrations": "See who signed up for workshops and accept registrations.", "Program Chair": "Plan each month\u2019s program and workshop, update where and when we meet, and email all members.", "Quilt Show Chair": "Show or hide the Quilt Show card, and edit its message and photos.", "Sunshine & Shadows Review": "Approve or decline notes from members.", "Membership Chair": "Review new member requests and manage the membership database.", "Newsletter Chair": "Add, edit and delete newsletters.", "President\u2019s Page": "Post and edit Special Notices.", "Reported Messages": "Review private messages that members have reported.", "Manage Notices": "Post, change, pin and remove the notices on this page.", "Roles & Permissions": "Choose who holds each Guild role and what each role can edit."};
  var PUBLIC=[{l:'Programs & Workshops',i:'programs-and-workshops',href:'programs.html'},{l:'Comfort Quilts',i:'comfort-quilts',href:'comfort-quilts.html'},{l:'Our Community',i:'our-community',href:'our-community.html'},{l:'About our Guild',i:'about-our-guild',href:'about-guild.html'}];
  var MEMBER=[{l:'Programs & Workshops',i:'programs-and-workshops',href:'programs.html'},{l:'Newsletters',i:'newsletters',href:'newsletters.html'},{l:'Block of the Month',i:'block-of-the-month',href:'block-of-the-month.html'},{l:'Member Directory',i:'member-directory',href:'directory.html'},{l:'Comfort Quilts',i:'comfort-quilts',href:'comfort-quilts.html'},{l:'Our Community',i:'our-community',href:'our-community.html'},{l:'Bees',i:'bees',href:'bees.html'},{l:'Retreats',i:'retreats',href:'retreats.html'},{l:'About our Guild',i:'about-our-guild',href:'about-guild.html'}];
  var JOBS=[
    {l:'Membership Chair',i:'membership',href:'membership.html',r:['membership_chair','superuser']},
    {l:'President’s Page',i:'presidents-page',href:'presidents-page.html',r:['president','vice_president'],adm:1},
    {l:'Newsletter Chair',i:'newsletter-manager',href:'newsletter-manager.html',r:['newsletter_chair'],adm:1},
    {l:'Sunshine & Shadows Review',i:'sunshine-and-shadows-review',href:'sunshine-review.html',r:['sunshine_shadows_chair'],adm:1},
    {l:'Comfort Quilts Chair',i:'comfort-quilts-manager',href:'comfort-manager.html',r:['comfort_quilts_chair'],adm:1},
    {l:'Bees Chair',i:'bees-manager',href:'bees-manage.html',r:['beekeeper'],adm:1},
    {l:'BOM Chair',i:'block-of-the-month-manager',href:'block-of-the-month-manage.html',r:['bom_chair'],adm:1},
    {l:'Workshop Registrations',i:'workshop-registrations',href:'workshop-registrations.html',r:['workshop_chair'],adm:1},
    {l:'Program Chair',i:'program-planning',r:['program_chair'],adm:1,href:'program-chair.html'},
    {l:'Edit In the News',i:'about',href:'in-the-news-manage.html',r:['publicity_chair'],adm:1},
    {l:'Retreat Chair',i:'retreats',href:'retreats-manage.html',r:['retreats_chair'],adm:1},
    {l:'Reported Messages',i:'reported-messages',href:'reported-messages.html',r:[],adm:1},
    {l:'Site Administration',i:'site-administration',href:'admin.html',r:[],adm:1}];
  var PER_BAR=14;
  // Superuser and Administrators have many job tiles, so Programs & Workshops starts the "More" list instead of ending the main bar.
  function order(jobs,full,isAdm){
    var all=jobs.concat(full?MEMBER:PUBLIC);
    if(!(isAdm&&full))return all;
    var i=-1;all.forEach(function(t,k){if(t.l==='Programs & Workshops'&&k>=jobs.length)i=k;});
    if(i<0)return all;
    var pw=all.splice(i,1)[0];all.splice(Math.min(PER_BAR,all.length),0,pw);return all;
  }
  var st=document.createElement('style');
  st.textContent='.tilebar .tile[aria-current="page"]{border-color:var(--cobalt);box-shadow:inset 0 0 0 2px var(--cobalt)}';
  document.head.appendChild(st);
  var box=document.createElement('div');
  box.innerHTML='<nav class="navbar" aria-label="Guild areas"><ul class="tilebar" id="tilebar"></ul>'+'<button type="button" class="tile morebtn hidden" id="more-btn" aria-expanded="false" aria-controls="more-areas">More <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path id="more-chev" d="M6 9l6 6 6-6"></path></svg></button>'+'</nav><ul class="tilebar morelist hidden" id="more-areas"></ul>';
  var ref=top.nextSibling;
  while(box.firstChild)top.parentNode.insertBefore(box.firstChild,ref);
  function tile(t){
    var li=document.createElement('li'),e=document.createElement(t.href?'a':'span');
    e.className='tile'+(t.href?'':' soon'); if(t.href)e.href=t.href; else e.tabIndex=0;
    if(t.href===cur)e.setAttribute('aria-current','page');
    var im=document.createElement('img');im.src=T(t.i);im.alt='';im.width=34;im.height=34;e.appendChild(im);
    var lab=document.createElement('span');lab.className='lab';lab.textContent=t.l;e.appendChild(lab);
    if(t.isNew&&!t.badge&&t.href!==cur){var nb=document.createElement('span');nb.className='badge';nb.textContent='New';nb.setAttribute('aria-label','New: something has changed on this page');e.appendChild(nb);}
    if(t.badge){var bd=document.createElement('span');bd.className='badge';bd.textContent=t.badge;bd.setAttribute('aria-label',t.badge+' '+(t.badgeLabel||(t.badge===1?'request waiting':'requests waiting')));e.appendChild(bd);}
    var tip=TIPS[t.l]||'';
    if(tip||!t.href){var tp=document.createElement('span');tp.className='tip';tp.setAttribute('role','tooltip');tp.appendChild(document.createTextNode(tip));
      if(!t.href){var em=document.createElement('em');em.textContent='Coming soon';tp.appendChild(em);}
      e.appendChild(tp);}
    li.appendChild(e);return li;
  }
  function fill(id,list){var u=$(id);u.textContent='';list.forEach(function(t){u.appendChild(tile(t));});}
  function show(all){
    fill('tilebar',all.slice(0,PER_BAR));
    if(all.length>PER_BAR){fill('more-areas',all.slice(PER_BAR));$('more-btn').classList.remove('hidden');}
    var s=document.createElement('script');s.src='assets/js/navmenu.js?v=20261118f';document.body.appendChild(s);
  }
  $('more-btn').addEventListener('click',function(){
    var o=$('more-areas').classList.toggle('hidden')===false;
    this.setAttribute('aria-expanded',o?'true':'false');
    $('more-chev').setAttribute('d',o?'M6 15l6-6 6 6':'M6 9l6 6 6-6');
    this.firstChild.nodeValue=o?'Less ':'More ';
  });
  function newKeys(){
    if(typeof QGPCNew!=='undefined')return Promise.resolve(QGPCNew);
    return new Promise(function(res){var s=document.createElement('script');s.src='assets/js/newbadge.js?v=20261118f';s.onload=function(){res(typeof QGPCNew!=='undefined'?QGPCNew:null);};s.onerror=function(){res(null);};document.body.appendChild(s);});
  }
  var sb=QGPC.sb,safe=function(p){return Promise.resolve(p).catch(function(){});};
  function addAccount(m,full){
    var nav=head.querySelector('nav.navbar');if(!nav||$('tb-avatar'))return;
    var ha=head.querySelector('.head-actions');
    if(ha){var wh=ha.querySelector('.whoami');if(wh)wh.parentNode.removeChild(wh);}
    // Sign out lives in the top row, at the far right (after the Facebook and Home links), as on Home.
    if(!document.getElementById('out')){
      var top2=head.querySelector('.head-top');
      if(!ha&&top2){ha=document.createElement('nav');ha.className='head-actions';ha.setAttribute('aria-label','Account');top2.appendChild(ha);}
      if(ha){var ob=document.createElement('button');ob.type='button';ob.className='pill out';ob.id='tb-out';ob.textContent='Sign out';
        ob.addEventListener('click',function(){QGPC.signOut().then(function(){location.href='index.html';});});ha.appendChild(ob);}
    }
    var d=document.createElement('div');
    d.innerHTML='<span class="vdiv" aria-hidden="true"></span><span class="pstack">'
      +'<a class="tile pill prof" href="profile.html"><span class="avatar" id="tb-avatar" aria-hidden="true"></span><span class="lab">My Profile</span><span class="tip" role="tooltip">Update your photo, contact details and quilting interests.</span></a>'
      +'<a class="tile pill msg hidden" id="tb-msg" href="messages.html"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 5h16v11H9l-5 4z"></path></svg><span class="lab">Messages</span><span class="badge hidden" id="tb-msgbadge"></span><span class="tip" role="tooltip">Send and read private messages with other members.</span></a>'
      +'</span>';
    while(d.firstChild)nav.appendChild(d.firstChild);
    $('tb-avatar').textContent=((m.first_name||'?').charAt(0)+(m.last_name||'').charAt(0)).toUpperCase();
    if(!full)return;
    $('tb-msg').classList.remove('hidden');
    safe(QGPC.sb.from('members').select('photo_path').eq('id',m.id).limit(1).then(function(r){
      var ph=r.data&&r.data[0]&&r.data[0].photo_path;if(!ph)return;
      return QGPC.sb.storage.from('member-photos').createSignedUrl(ph,3600).then(function(x){
        if(!x.data||!x.data.signedUrl)return;
        var av=$('tb-avatar'),im=document.createElement('img');im.src=x.data.signedUrl;im.alt='';im.style.cssText='width:100%;height:100%;border-radius:50%;object-fit:cover';
        av.textContent='';av.appendChild(im);});
    }));
    safe(QGPC.sb.rpc('unread_message_count').then(function(r){
      var n=(!r.error&&r.data>0)?r.data:0,b=$('tb-msgbadge');b.textContent=n;b.classList.toggle('hidden',!n);
      b.setAttribute('aria-label',n+' unread '+(n===1?'message':'messages'));
    }));
  }
  QGPC.session().then(function(s){
    if(!s){show(PUBLIC);return;}
    return sb.from('members_with_status').select('*').eq('auth_user_id',s.user.id).limit(1).then(function(r){
      if(r.error||!r.data||!r.data.length){show(PUBLIC);return;}
      var m=r.data[0];
      return sb.from('member_roles').select('role_key').eq('member_id',m.id).then(function(rr){
        var held=(rr.data||[]).map(function(x){return x.role_key;});
        // Same "Acting as" choice as the Home page (kept for this browser tab only).
        var pick=null;try{pick=sessionStorage.getItem('qgpc_acting');}catch(e){}
        if(pick&&pick!=='member'&&held.indexOf(pick)<0)pick=null;
        if(held.length===0)pick=null;
        var roles=pick?(pick==='member'?[]:[pick]):held;
        var has=function(k){return roles.indexOf(k)>-1;};
        var isAdm=has('superuser')||has('administrator');
        var full=isAdm||m.status==='active'||m.status==='grace';   // Inactive members are treated like visitors
        addAccount(m,full);
        var jobs=!full?[]:JOBS.filter(function(j){
          if(j.only)return has('superuser');
          if(isAdm&&(j.adm||(j.r.indexOf('superuser')>-1&&has('superuser'))))return true;
          return j.r.some(has);
        });
        var one=function(l){return jobs.filter(function(j){return j.l===l;})[0];};
        var mt=one('Membership Chair'),cq=one('Comfort Quilts Chair'),sr=one('Sunshine & Shadows Review'),rmj=one('Reported Messages'),sa=one('Site Administration');
        var p=[];
        if(mt)p.push(safe(sb.from('membership_requests').select('id',{count:'exact',head:true}).in('status',['new','paid']).then(function(r){mt.badge=(!r.error&&r.count>0)?r.count:0;})));
        if(cq)p.push(safe(sb.rpc('comfort_chair_counts').then(function(r){var d=r&&r.data;if(Array.isArray(d))d=d[0];var n=(!r.error&&d)?(d.new_quilts||0)+(d.new_kits||0):0;cq.badge=n;cq.badgeLabel='new claims';})));
        if(sr)p.push(safe(sb.rpc('sunshine_pending_count').then(function(r){sr.badge=(!r.error&&r.data>0)?r.data:0;sr.badgeLabel='notes waiting';})));
        if(rmj)p.push(safe(sb.rpc('reported_messages_waiting').then(function(r){var n=(!r.error&&r.data>0)?r.data:0;rmj.badge=n;rmj.badgeLabel=n===1?'report waiting':'reports waiting';})));
        if(isAdm&&sa)p.push(safe(sb.rpc('backup_status').then(function(r){var d=r&&r.data;if(r.error||!d||!d.due)return;sa.badge='!';sa.badgeLabel='a backup is due';})));
        var NEWKEYS={'Programs & Workshops':['programs'],'Block of the Month':['bom'],'Newsletters':['newsletters'],'Member Directory':['directory'],'Comfort Quilts':['comfort'],'Our Community':['sunshine','news'],'Retreats':['retreats'],'Bees':['bees'],'About our Guild':['about']};
        if(full)p.push(safe(newKeys().then(function(N){if(!N)return;return N.me().then(N.keys).then(function(nk){MEMBER.forEach(function(t){t.isNew=(NEWKEYS[t.l]||[]).some(function(k){return nk[k];});});});})));
        return Promise.all(p).then(function(){show(order(jobs,full,isAdm));});
      });
    });
  }).catch(function(){show(PUBLIC);});
})();
