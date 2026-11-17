// Phone menu: on narrow screens the area tiles in the page header are hidden behind a "Menu" button.
// The CSS only hides tiles once this script has added the "navm" class, so without JavaScript the tiles stay visible.
(function(){
  var h=document.querySelector('.site-head');if(!h)return;
  var nav=h.querySelector('nav.navbar'),ul=h.querySelector('ul.tiles');
  var host=nav||ul;if(!host)return;
  var ctl=[];
  if(nav){['tilebar','more-areas'].forEach(function(i){if(document.getElementById(i))ctl.push(i);});}
  else{if(!ul.id)ul.id='site-tiles';ctl.push(ul.id);}
  var b=document.createElement('button');
  b.type='button';b.className='tile menubtn';b.setAttribute('aria-expanded','false');b.setAttribute('aria-controls',ctl.join(' '));
  b.innerHTML='<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16"></path></svg><span class="lab">Menu</span>';
  b.addEventListener('click',function(){
    var o=h.classList.toggle('nav-open');
    b.setAttribute('aria-expanded',o?'true':'false');
    b.querySelector('.lab').textContent=o?'Close menu':'Menu';
  });
  if(nav)nav.insertBefore(b,nav.firstChild);else ul.parentNode.insertBefore(b,ul);
  h.classList.add('navm');
})();
