// When a "See the ... page" button opens a page, that page shows a back link to where the button was.
// The button adds ?back=<page name>. Only the names listed here work, so the address cannot send
// anyone elsewhere. A new "See" button needs its page added to this list.
(function(){
  var FROM={
    'bees-manage':'Beekeeper',
    'block-of-the-month-manage':'Block of the Month Chair',
    'calendars-manage':'Calendars',
    'charities-manage':'Manage Charities',
    'comfort-manager':'Comfort Quilts Manager',
    'comfort-page-admin':'Comfort Quilts Page Admin',
    'guild-history-manage':'Edit Guild History',
    'membership':'Membership Chair',
    'mission-statement-manage':'Edit Mission Statement',
    'newsletter-manager':'Newsletter Chair',
    'pattern-library-manage':'Manage the Pattern Library',
    'privacy-manage':'Privacy Notice editor',
    'program-chair':'Program Chair',
    'publicity-chair':'Publicity Chair',
    'quilts-needing-work-manage':'Quilts Needing Work Manager',
    'retreats-manage':'Retreat Chair',
    'sunshine-review':'Sunshine & Shadows Review',
    'welcome-message-manage':'Welcome Message',
    'workshop-registrations':'Workshop Registrations'
  };
  var key=(location.search.match(/[?&]back=([a-z-]+)/)||[])[1];
  if(!Object.prototype.hasOwnProperty.call(FROM,key))return;
  var main=document.getElementById('main');if(!main)return;
  // this link takes the place of the page's usual back link
  [].forEach.call(main.querySelectorAll('a.backlink'),function(a){a.style.display='none';});
  var a=document.createElement('a');a.className='backlink';a.id='returnlink';a.href=key+'.html';
  a.innerHTML='<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 5l-7 7 7 7"></path></svg>';
  a.appendChild(document.createTextNode('Back to '+FROM[key]));
  var box=main.querySelector('.mwrap');
  if(!box){box=document.createElement('div');box.style.cssText='max-width:1200px;margin:0 auto;padding:8px 24px';main.insertBefore(box,main.firstChild);}
  box.insertBefore(a,box.firstChild);
})();
