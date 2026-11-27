// The Quilting Interests check boxes. The choices are edited on interests-manage.html.
// QGPCInterests.load(sb) -> Promise of {names, ok}. ok is false when the list could not be
// read; the starting choices are shown then, and pages must not drop other saved interests.
(function(){
  var START=['Piecing','Applique','Paper Piecing','English Paper Piecing','Modern Quilts','Color Theory','Hand Quilting','Embroidery'];
  window.QGPCInterests={
    load:function(sb){
      var no=function(){return {names:START.slice(),ok:false};};
      return sb.from('interest_choices').select('name').order('sort_order').order('name').then(function(r){
        return r.error||!r.data?no():{names:r.data.map(function(x){return x.name;}),ok:true};
      },no);
    },
    render:function(box,field,names){
      box.textContent='';
      names.forEach(function(n){
        var l=document.createElement('label');l.className='chk';
        var i=document.createElement('input');i.type='checkbox';i.name=field;i.value=n;
        l.appendChild(i);l.appendChild(document.createTextNode(' '+n));box.appendChild(l);
      });
    }
  };
})();
