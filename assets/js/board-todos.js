// Board To-Do List: shared by the member home card, the President's Page and the list page.
// Requires auth.js first.
(function(){
  var MONTHS=['January','February','March','April','May','June','July','August','September','October','November','December'];
  function el(t,cls,txt){var e=document.createElement(t);if(cls)e.className=cls;if(txt!=null)e.textContent=txt;return e;}
  function today(){return new Intl.DateTimeFormat('en-CA',{timeZone:'America/Chicago',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());}
  function nice(d){var p=d.split('-');return MONTHS[+p[1]-1].slice(0,3)+' '+(+p[2])+', '+p[0];}

  var T=window.QGPCTodos={
    ROLES:[],   // Board and committee chair roles, filled by load()
    MONTHS:MONTHS, el:el, nice:nice,
    now:function(){var d=today();return {year:+d.slice(0,4),month:+d.slice(5,7)};},
    // Any Executive Board or committee chair role (everything except the two site administration roles).
    isBoard:function(roles){return roles.some(function(k){return k!=='superuser'&&k!=='administrator';});},
    applies:function(t,year){return year>=t.first_year&&(t.last_year==null||year<=t.last_year);},
    // -> {items, done:{'id|year':row}, holders:{role:[names]}}; rejects if the list cannot be read
    load:function(){
      var sb=QGPC.sb;
      return Promise.all([
        sb.from('board_todos').select('*').order('month').order('created_at'),
        sb.from('board_todo_done').select('*'),
        sb.rpc('about_leaders'),
        sb.from('roles').select('role_key,label,sort_order').order('sort_order')
      ]).then(function(r){
        if(r[0].error||r[1].error||r[3].error)throw (r[0].error||r[1].error||r[3].error);
        T.ROLES=(r[3].data||[]).filter(function(x){return x.sort_order>=10;});
        var done={},holders={};
        (r[1].data||[]).forEach(function(d){done[d.todo_id+'|'+d.year]=d;});
        ((r[2]&&r[2].data)||[]).forEach(function(x){(holders[x.role_key]=holders[x.role_key]||[]).push(x.first_name+' '+x.last_name);});
        return {items:r[0].data||[],done:done,holders:holders};
      });
    },
    assigned:function(t,holders){
      return T.ROLES.filter(function(r){return t.roles.indexOf(r.role_key)>-1;}).map(function(r){
        var n=holders&&holders[r.role_key];return r.label+(n?' ('+n.join(', ')+')':'');
      }).join(', ');
    },
    // One task with its check box for one year.
    // o = {data, year, roles (of the viewer), manage, changed() reload, fail(text), yours: show a "Yours" tag}
    row:function(t,o){
      var key=t.id+'|'+o.year,d=o.data.done[key],now=T.now();
      var mine=t.roles.some(function(k){return o.roles.indexOf(k)>-1;});
      var can=o.manage||mine;
      var li=el('li','td'+(d?' done':''));
      var lab=el('label','td-main');
      var box=el('input');box.type='checkbox';box.checked=!!d;box.disabled=!can;
      if(!can)box.title='Only the assigned role, the President or Vice President can mark this.';
      var body=el('span','td-body');
      var head=el('span','td-title',t.title);
      if(o.yours&&mine)head.appendChild(el('span','chip blue','Yours'));
      if(!d&&(o.year<now.year||(o.year===now.year&&t.month<now.month)))head.appendChild(el('span','chip rust','Not done'));
      body.appendChild(head);
      if(t.details)body.appendChild(el('span','td-sub',t.details));
      body.appendChild(el('span','td-sub','Assigned to: '+T.assigned(t,o.data.holders)));
      if(d)body.appendChild(el('span','td-by','Completed by '+(d.completed_name||'a former member')+' on '+nice(d.completed_on)));
      lab.appendChild(box);lab.appendChild(body);li.appendChild(lab);
      function failed(){o.fail('That did not save. Please refresh the page and try again.');}
      box.addEventListener('change',function(){
        if(box.checked){
          box.disabled=true;
          QGPC.sb.from('board_todo_done').insert({todo_id:t.id,year:o.year}).then(function(r){
            // 23505 = someone else ticked it first; reloading shows their name
            if(r.error&&r.error.code!=='23505'){box.checked=false;box.disabled=false;failed();return;}
            o.changed();
          });
        }else{
          // Unticking throws away the name and date, so ask first.
          box.checked=true;box.disabled=true;
          var cf=el('div','confirm');
          cf.appendChild(el('p',null,'Mark this as not done? The name and date will be removed.'));
          var row=el('div','saverow');
          var y=el('button','btn-del solid','Yes, not done');y.type='button';
          var k=el('button','btn-cancel','Keep it');k.type='button';
          k.onclick=function(){li.removeChild(cf);box.disabled=false;box.focus();};
          y.onclick=function(){
            y.disabled=true;
            QGPC.sb.from('board_todo_done').delete().eq('todo_id',t.id).eq('year',o.year).select().then(function(r){
              if(r.error||!r.data||!r.data.length){y.disabled=false;failed();return;}
              o.changed();
            });
          };
          row.appendChild(y);row.appendChild(k);cf.appendChild(row);li.appendChild(cf);y.focus();
        }
      });
      return li;
    }
  };
})();
