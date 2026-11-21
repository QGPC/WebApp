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
    var W=612,H=792,M=44,GAP=24,CW=(W-2*M-GAP)/2,LH=11.5,BOTTOM=H-M-6;
    var TITLE='Quilter’s Guild of Parker County';
    doc.setProperties({title:'Member Directory - '+clean(TITLE),subject:'Member Directory',author:clean(TITLE)});
    var col=0,y=0,first=true;
    function colX(){return M+col*(CW+GAP);}
    function pageTop(){
      if(first){
        doc.setFont('helvetica','bold');doc.setFontSize(18);doc.setTextColor(1,67,95);doc.text(clean(TITLE),M,M+10);
        doc.setFontSize(13);doc.text('Member Directory',M,M+28);
        doc.setFont('helvetica','normal');doc.setFontSize(9);doc.setTextColor(60,60,60);
        doc.text('Current members who are listed in the directory. Printed '+clean(dateText)+'.',M,M+42);
        doc.setDrawColor(1,125,176);doc.setLineWidth(1.2);doc.line(M,M+50,W-M,M+50);
        y=M+68;first=false;
      }else{y=M+8;}
      col=0;
    }
    function nextColumn(){
      if(col===0){col=1;y=(doc.getNumberOfPages()===1)?M+68:M+8;}
      else{doc.addPage();pageTop();}
    }
    function fit(h){if(y+h>BOTTOM)nextColumn();}
    pageTop();
    var lastLetter='';
    rows.forEach(function(r){
      var name=clean((r.last_name||'')+(r.first_name?', '+r.first_name:''))||'(no name)';
      var letter=name.normalize('NFD').replace(/[\u0300-\u036f]/g,'').charAt(0).toUpperCase();if(!/[A-Z]/.test(letter))letter='#';
      doc.setFont('helvetica','normal');doc.setFontSize(9);
      var lines=[];
      var a=clean(addr(r));if(a)doc.splitTextToSize(a,CW-6).forEach(function(l){lines.push(l);});
      if(r.cell_phone)lines.push(clean(r.cell_phone));
      if(r.email)doc.splitTextToSize(clean(r.email),CW-6).forEach(function(l){lines.push(l);});
      var h=LH+lines.length*LH+8;
      var needHead=(letter!==lastLetter);
      fit((needHead?24:0)+h);
      if(needHead){
        doc.setFont('helvetica','bold');doc.setFontSize(12);doc.setTextColor(1,87,174);
        doc.text(letter,colX(),y+10);
        doc.setDrawColor(190,190,190);doc.setLineWidth(0.5);doc.line(colX()+16,y+7,colX()+CW,y+7);
        y+=24;lastLetter=letter;
      }
      doc.setFont('helvetica','bold');doc.setFontSize(10);doc.setTextColor(20,20,20);
      doc.text(name,colX(),y+9);
      doc.setFont('helvetica','normal');doc.setFontSize(9);doc.setTextColor(50,50,50);
      var yy=y+9+LH;
      lines.forEach(function(l){doc.text(l,colX()+6,yy);yy+=LH;});
      y+=h;
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
