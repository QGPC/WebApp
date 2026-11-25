// Builds the Member Directory PDF (name, address, phone, email) from the rows the Directory page already loaded.
// Needs jsPDF (assets/js/jspdf.umd.min.js). Nothing is sent anywhere: the file is made in the browser.
// QGPCDirPdf.build(jsPDF, rows, dateText) returns a jsPDF document; the page saves it.
(function(root){
  // Standard PDF fonts only cover Latin-1, so curly quotes become straight and other letters lose their accents.
  function clean(s){
    s=String(s==null?'':s).replace(/[‘’‛]/g,"'").replace(/[“”]/g,'"').replace(/[–—]/g,'-').replace(/…/g,'...').replace(/ /g,' ');
    var out='';
    for(var i=0;i<s.length;i++){
      var ch=s.charAt(i);
      if(ch.charCodeAt(0)<=255){out+=ch;continue;}
      var base=ch.normalize('NFD').replace(/[̀-ͯ]/g,'');
      out+=(base&&base.charCodeAt(0)<=255)?base:'?';
    }
    return out.replace(/\s+/g,' ').trim();
  }
  function addr(r){
    var l2=[r.city,[r.state,r.zip].filter(Boolean).join(' ')].filter(Boolean).join(', ');
    return [r.street_address,l2].filter(Boolean).join(', ');
  }
  function build(JsPDF,rows,dateText){
    var doc=new JsPDF({unit:'pt',format:'letter'});
    var W=612,H=792,M=44,GAP=16,COLS=3,CW=(W-2*M-(COLS-1)*GAP)/COLS,LH=11.5,BOTTOM=H-M-6;
    var TITLE='Quilter’s Guild of Parker County';
    doc.setProperties({title:'Member Directory - '+clean(TITLE),subject:'Member Directory',author:clean(TITLE)});
    var y=0,first=true;
    function pageTop(){
      if(first){
        doc.setFont('helvetica','bold');doc.setFontSize(18);doc.setTextColor(1,67,95);doc.text(clean(TITLE),M,M+10);
        doc.setFontSize(13);doc.text('Member Directory',M,M+28);
        doc.setFont('helvetica','normal');doc.setFontSize(9);doc.setTextColor(60,60,60);
        doc.text('Current members who are listed in the directory. Printed '+clean(dateText)+'.',M,M+42);
        doc.setDrawColor(1,125,176);doc.setLineWidth(1.2);doc.line(M,M+50,W-M,M+50);
        y=M+68;first=false;
      }else{y=M+8;}
    }
    pageTop();
    var ents=rows.map(function(r){
      var name=clean((r.last_name||'')+(r.first_name?', '+r.first_name:''))||'(no name)';
      var letter=name.normalize('NFD').replace(/[\u0300-\u036f]/g,'').charAt(0).toUpperCase();if(!/[A-Z]/.test(letter))letter='#';
      doc.setFont('helvetica','normal');doc.setFontSize(9);
      var lines=[],wide=CW-6;
      var a=clean(addr(r));
      if(a){var st=clean(r.street_address),town=clean([r.city,[r.state,r.zip].filter(Boolean).join(' ')].filter(Boolean).join(', '));
        if(doc.getTextWidth(a)<=wide)lines.push(a);   // otherwise street and town go on their own lines
        else [st,town].filter(Boolean).forEach(function(p){doc.splitTextToSize(p,wide).forEach(function(l){lines.push(l);});});}
      if(r.cell_phone)lines.push(clean(r.cell_phone));
      if(r.email){var em=clean(r.email),at=em.indexOf('@');   // a long address breaks before the @
        var parts=(doc.getTextWidth(em)>wide&&at>0)?[em.slice(0,at),em.slice(at)]:[em];
        parts.forEach(function(p){doc.splitTextToSize(p,wide).forEach(function(l){lines.push(l);});});}
      doc.setFont('helvetica','bold');doc.setFontSize(10);
      var names=doc.splitTextToSize(name,CW);
      return {names:names,letter:letter,lines:lines,h:(names.length+lines.length)*LH+8};
    });
    function drawEntry(e,x,yy){
      doc.setFont('helvetica','bold');doc.setFontSize(10);doc.setTextColor(20,20,20);
      var t=yy+9;e.names.forEach(function(l){doc.text(l,x,t);t+=LH;});
      doc.setFont('helvetica','normal');doc.setFontSize(9);doc.setTextColor(50,50,50);
      e.lines.forEach(function(l){doc.text(l,x+6,t);t+=LH;});
    }
    // Fill up to COLS columns, top to bottom then left to right, none taller than lim
    function pack(list,lim){
      var cols=[],tall=0,i=0;
      for(var c=0;c<COLS&&i<list.length;c++){
        var col=[],h=0;
        while(i<list.length&&(h+list[i].h<=lim||!col.length)){h+=list[i].h;col.push(list[i++]);}
        cols.push(col);tall=Math.max(tall,h);
      }
      return {cols:cols,used:i,h:tall};
    }
    function band(letter,cont){
      doc.setFillColor(232,240,248);doc.rect(M,y,W-2*M,20,'F');
      doc.setFont('helvetica','bold');doc.setFontSize(13);doc.setTextColor(1,87,174);
      doc.text(letter+(cont?'  (continued)':''),M+8,y+14.5);
      y+=26;
    }
    var letters=[];ents.forEach(function(e){if(letters.indexOf(e.letter)<0)letters.push(e.letter);});
    letters.forEach(function(L){
      var list=ents.filter(function(e){return e.letter===L;}),cont=false;
      while(list.length){
        if(y+26+list[0].h>BOTTOM){doc.addPage();pageTop();}
        var space=BOTTOM-(y+26);
        var T=list.reduce(function(s,e){return s+e.h;},0),maxH=Math.max.apply(null,list.map(function(e){return e.h;}));
        // the shortest column height that holds the whole letter, so the columns come out about even
        var lim=Math.min(space,Math.max(maxH,T/COLS));
        while(lim<space&&pack(list,lim).used<list.length)lim=Math.min(space,lim+2);
        var p3=pack(list,lim);list=list.slice(p3.used);
        band(L,cont);
        p3.cols.forEach(function(col,c){var yy=y;col.forEach(function(e){drawEntry(e,M+c*(CW+GAP),yy);yy+=e.h;});});
        y+=p3.h+6;cont=true;
      }
    });
    var n=doc.getNumberOfPages();
    for(var p=1;p<=n;p++){
      doc.setPage(p);
      doc.setFont('helvetica','normal');doc.setFontSize(8);doc.setTextColor(90,90,90);
      doc.setDrawColor(190,190,190);doc.setLineWidth(0.5);doc.line(M,H-M+2,W-M,H-M+2);
      doc.text('For Guild members only. Please don\'t share members\' contact details outside the Guild.',M,H-M+14);
      var pg='Page '+p+' of '+n;doc.text(pg,W-M-doc.getTextWidth(pg),H-M+14);
    }
    return doc;
  }
  root.QGPCDirPdf={build:build,clean:clean};
  if(typeof module!=='undefined'&&module.exports)module.exports=root.QGPCDirPdf;
})(typeof window!=='undefined'?window:globalThis);
