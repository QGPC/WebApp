// Draws the Privacy Notice text into a box. Used by privacy.html and privacy-manage.html (preview).
// Text rules (also shown on the editor page): a blank line starts a new block; a line that begins
// with "## " is a heading; lines that begin with "- " are a bulleted list; anything else is a paragraph.
// Everything is set with textContent, so typed-in markup is shown as plain text, never run.
(function(){
  function el(tag,txt){var e=document.createElement(tag);if(txt!=null)e.textContent=txt;return e;}
  window.QGPCPrivacy={
    render:function(text,box){
      box.textContent='';
      String(text||'').replace(/\r\n?/g,'\n').split(/\n{2,}/).forEach(function(blk){
        var lines=blk.split('\n').map(function(l){return l.trim();}).filter(Boolean),ul=null,para=[];
        function flush(){if(para.length){box.appendChild(el('p',para.join(' ')));para=[];}}
        lines.forEach(function(l){
          var h=l.match(/^##\s+(.*)$/),b=l.match(/^[-*]\s+(.*)$/);
          if(h){flush();ul=null;box.appendChild(el('h2',h[1]));}
          else if(b){flush();if(!ul){ul=el('ul');box.appendChild(ul);}ul.appendChild(el('li',b[1]));}
          else{ul=null;para.push(l);}
        });
        flush();
      });
    },
    brackets:function(text){return (String(text||'').match(/\[[^\]\n]{2,}\]/g)||[]).length;}
  };
})();
