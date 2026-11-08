import Foundation

/// Strona otwierana w przeglądarce telewizora / komputera / drugiego telefonu w tej samej sieci Wi‑Fi.
/// Pokazuje przewijany tekst z animacją, ma przyciski sterowania (ikony SVG), przycisk wyjścia i ukrywania tekstu,
/// a po połączeniu sama uruchamia odtwarzanie i może grać dźwięk z telefonu.
enum RemoteLyricsPage {
    static let html = #"""
<!doctype html>
<html lang="pl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>Music Player</title>
<style>
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;height:100%;background:#0b0b12;color:#fff;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;overflow:hidden}
button{font-family:inherit;color:inherit;border:0;outline:0;cursor:pointer}
svg{display:block;fill:currentColor}
#bg{position:fixed;left:-8%;top:-8%;width:116%;height:116%;background-size:cover;background-position:center;-webkit-filter:blur(34px) brightness(.5) saturate(1.3);filter:blur(34px) brightness(.5) saturate(1.3);-webkit-transform:translateZ(0);transform:translateZ(0)}
#wrap{position:relative;height:100%;display:-webkit-box;display:flex;-webkit-box-orient:vertical;flex-direction:column;padding:2.5vh 4vw}
#head{display:-webkit-box;display:flex;-webkit-box-align:center;align-items:center}
#cover{width:11vh;height:11vh;min-width:64px;min-height:64px;border-radius:14px;background:#222 center/cover;margin-right:3vw;-webkit-flex-shrink:0;flex-shrink:0;box-shadow:0 8px 30px rgba(0,0,0,.45)}
#meta{-webkit-box-flex:1;flex:1;min-width:0}
#title{font-size:3.8vh;font-weight:800;line-height:1.15;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#artist{font-size:2.5vh;opacity:.7;margin-top:.4vh;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#live{font-size:1.8vh;font-weight:700;opacity:.75;margin-top:.5vh}
.tools{display:-webkit-box;display:flex;margin-left:2vw}
.ib{width:6.4vh;height:6.4vh;min-width:46px;min-height:46px;border-radius:50%;background:rgba(255,255,255,.14);display:-webkit-box;display:flex;-webkit-box-align:center;align-items:center;justify-content:center;margin-left:1.2vw;-webkit-transition:background .2s;transition:background .2s}
.ib svg{width:46%;height:46%}
.ib.on{background:rgba(255,255,255,.9);color:#111}
.ib:focus,.btn:focus,.pill:focus{box-shadow:0 0 0 3px #fff}
#lyr{position:relative;-webkit-box-flex:1;flex:1;overflow-y:auto;overflow-x:hidden;-webkit-overflow-scrolling:touch;margin-top:1.5vh;scrollbar-width:none;-ms-overflow-style:none;-webkit-mask-image:linear-gradient(to bottom,transparent 0,#000 9%,#000 88%,transparent 100%);mask-image:linear-gradient(to bottom,transparent 0,#000 9%,#000 88%,transparent 100%)}
#lyr::-webkit-scrollbar{display:none}
#list{position:relative;padding:22vh 0 55vh}
.line{font-size:5vh;font-weight:800;line-height:1.22;padding:1.4vh 0;opacity:.38;-webkit-transition:opacity .3s;transition:opacity .3s}
.line.n1{opacity:.55}
.line.on{opacity:1}
.plain{font-size:3.4vh;font-weight:700;line-height:1.4;white-space:pre-wrap;opacity:.92;padding:2vh 0}
.msg{font-size:3.4vh;font-weight:700;opacity:.65;text-align:center;margin-top:10vh}
#hero{display:none;-webkit-box-flex:1;flex:1;-webkit-box-orient:vertical;flex-direction:column;-webkit-box-align:center;align-items:center;justify-content:center;min-height:0}
#herocover{width:46vh;height:46vh;max-width:80vw;max-height:80vw;border-radius:22px;background:#222 center/cover;box-shadow:0 18px 50px rgba(0,0,0,.5)}
body.nolyr #lyr{display:none}
body.nolyr #hero{display:-webkit-box;display:flex}
#bar{height:5px;border-radius:3px;background:rgba(255,255,255,.2);margin:1.5vh 0 .5vh;overflow:hidden}
#fill{display:block;height:100%;width:0;background:#fff}
#ctl{display:-webkit-box;display:flex;-webkit-box-pack:center;justify-content:center;-webkit-box-align:center;align-items:center;padding:.5vh 0}
.btn{background:transparent;width:9vh;height:9vh;min-width:64px;min-height:64px;border-radius:50%;display:-webkit-box;display:flex;-webkit-box-align:center;align-items:center;justify-content:center;margin:0 2.5vw}
.btn svg{width:46%;height:46%}
.btn.big{background:rgba(255,255,255,.95);color:#111;width:11vh;height:11vh;min-width:78px;min-height:78px}
.btn.big svg{width:48%;height:48%}
#st{font-size:1.8vh;opacity:.75;text-align:center;min-height:2.4vh}
.ov{position:fixed;left:0;top:0;right:0;bottom:0;background:rgba(8,8,14,.9);display:none;-webkit-box-orient:vertical;flex-direction:column;-webkit-box-align:center;align-items:center;justify-content:center;text-align:center;padding:6vh 8vw;z-index:10}
.ov.show{display:-webkit-box;display:flex}
.ov h1{font-size:4.4vh;margin:0 0 1.2vh}
.ov p{font-size:2.5vh;opacity:.75;margin:0 0 3.5vh;max-width:60ch}
.pill{display:-webkit-box;display:flex;-webkit-box-align:center;align-items:center;justify-content:center;font-size:2.6vh;font-weight:700;padding:1.8vh 4vh;border-radius:99px;background:rgba(255,255,255,.16);margin:1vh 0;min-width:34vh}
.pill svg{width:3.4vh;height:3.4vh;margin-right:1.2vh}
.pill.main{background:#fff;color:#111}
@media (max-aspect-ratio:1/1){
  .line{font-size:4.6vw}.plain{font-size:4vw}.msg{font-size:4.4vw}#title{font-size:4.8vw}#artist{font-size:3.4vw}
  .ov h1{font-size:6vw}.ov p{font-size:3.8vw}.pill{font-size:4vw}#herocover{width:78vw;height:78vw}
}
</style>
</head>
<body>
<div id="bg"></div>
<div id="wrap">
  <div id="head">
    <div id="cover"></div>
    <div id="meta"><div id="title">Łączenie…</div><div id="artist"></div><div id="live"></div></div>
    <div class="tools">
      <button class="ib" id="btxt" tabindex="0" title="Tekst"></button>
      <button class="ib" id="bsound" tabindex="0" title="Dźwięk na tym urządzeniu"></button>
      <button class="ib" id="bexit" tabindex="0" title="Wyjdź"></button>
    </div>
  </div>
  <div id="lyr"><div id="list"></div></div>
  <div id="hero"><div id="herocover"></div></div>
  <div id="bar"><i id="fill"></i></div>
  <div id="ctl">
    <button class="btn" id="bprev" tabindex="0"></button>
    <button class="btn big" id="bplay" tabindex="0"></button>
    <button class="btn" id="bnext" tabindex="0"></button>
  </div>
  <div id="st"></div>
</div>
<div class="ov show" id="start">
  <h1>Połączono z telefonem</h1>
  <p>Wybierz, gdzie ma grać dźwięk. Tekst piosenki i przyciski sterowania są zawsze na tym ekranie.</p>
  <button class="pill main" id="gosound" tabindex="0"></button>
  <button class="pill" id="goquiet" tabindex="0">Tylko tekst i sterowanie</button>
</div>
<div class="ov" id="bye">
  <h1>Rozłączono</h1>
  <p>Dźwięk wrócił na telefon. Możesz zamknąć tę kartę.</p>
  <button class="pill main" id="again" tabindex="0">Połącz ponownie</button>
</div>
<div class="ov" id="tap">
  <h1>Dźwięk wstrzymany</h1>
  <p>Przeglądarka wymaga dotknięcia, żeby zagrać dźwięk.</p>
  <button class="pill main" id="taptap" tabindex="0"></button>
</div>
<audio id="au" preload="auto"></audio>
<script>
(function(){
var P={
 play:'M8 5v14l11-7z',
 pause:'M6 19h4V5H6v14zm8-14v14h4V5h-4z',
 prev:'M6 6h2v12H6zM9.5 12l8.5 6V6z',
 next:'M6 18l8.5-6L6 6v12zM16 6v12h2V6h-2z',
 snd:'M3 9v6h4l5 5V4L7 9H3zM16.5 12A4.5 4.5 0 0 0 14 7.97v8.05c1.5-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z',
 txt:'M4 5h16v2H4zM4 9h16v2H4zM4 13h10v2H4zM4 17h16v2H4z',
 x:'M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z'
};
function ic(n){ return '<svg viewBox="0 0 24 24" width="24" height="24"><path d="'+P[n]+'"/></svg>'; }
var S=null, recv=0, L=null, lyrVer=-1, rows=[], active=-1, soundOn=false, greeted=false, left=false, timer=0;
var userUntil=0, userMoved=false, tw=null, targetY=0, lastPaint=0;
var au=document.getElementById('au');
var SILENT='data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEAESsAACJWAAACABAAZGF0YQAAAAA=';
function $(i){return document.getElementById(i);}
function now(){return Date.now();}
function get(url,cb){
  var r=new XMLHttpRequest();
  r.open('GET',url+(url.indexOf('?')<0?'?':'&')+'_='+now(),true);
  r.timeout=4000;
  r.onload=function(){ if(r.status===200){ try{ cb(JSON.parse(r.responseText)); }catch(e){} } };
  r.onerror=function(){ if(!left) $('st').textContent='Brak połączenia z telefonem…'; };
  r.ontimeout=r.onerror;
  r.send();
}
function cmd(c,q){ var r=new XMLHttpRequest(); r.open('GET','/cmd/'+c+(q||'')+(q?'&':'?')+'_='+now(),true); r.send(); }
function pos(){ if(!S) return 0; return S.pos+(S.playing?(now()-recv)/1000:0); }
function clamp(x){ return x<0?0:(x>1?1:x); }

function tryPlay(){
  var p=au.play();
  if(p&&p.catch) p.catch(function(){ if(soundOn&&!left) $('tap').className='ov show'; });
}
function setIcons(){
  $('bprev').innerHTML=ic('prev'); $('bnext').innerHTML=ic('next');
  $('bplay').innerHTML=ic('play'); $('btxt').innerHTML=ic('txt');
  $('bsound').innerHTML=ic('snd'); $('bexit').innerHTML=ic('x');
  $('gosound').innerHTML=ic('snd')+'Graj dźwięk tutaj'; $('taptap').innerHTML=ic('play')+'Włącz dźwięk';
}

function poll(){
  if(left) return;
  get('/state',function(s){
    var changedTrack=!S||S.tid!==s.tid;
    var coverChanged=!S||S.cv!==s.cv;
    S=s; recv=now();
    $('st').textContent='';
    $('title').textContent=s.title||'';
    $('artist').textContent=s.artist||'';
    $('live').textContent=s.radio?('NA ŻYWO'+(s.station?' · '+s.station:'')):'';
    $('bplay').innerHTML=ic(s.playing?'pause':'play');
    if(coverChanged){ var u='url(/cover?v='+s.cv+')'; $('cover').style.backgroundImage=u; $('herocover').style.backgroundImage=u; $('bg').style.backgroundImage=u; }
    if(s.lver!==lyrVer || changedTrack){ lyrVer=s.lver; loadLyrics(); }
    if(!greeted){ greeted=true; if(s.tid && !s.playing) cmd('play'); }   // po połączeniu telefon od razu zaczyna grać
    if(!s.audio && soundOn){ $('st').textContent='Ta piosenka jeszcze się pobiera na telefonie - dźwięk będzie za chwilę.'; }
    syncAudio();
  });
}

function loadLyrics(){ get('/lyrics',function(d){ L=d; build(); }); }

function build(){
  var list=$('list'); list.innerHTML=''; rows=[]; active=-1; tw=null;
  $('lyr').scrollTop=0;
  if(!L) return;
  if(L.kind==='synced'){
    for(var i=0;i<L.rows.length;i++){
      var r=L.rows[i], div=document.createElement('div');
      div.className='line';
      var text=r.a.join('');
      div.textContent=text;
      list.appendChild(div);
      rows.push({t:r.t,c:r.c,f:r.f,a:r.a,el:div,txt:text,sp:null});
    }
  } else if(L.kind==='plain'){
    var p=document.createElement('div'); p.className='plain'; p.textContent=L.text||''; list.appendChild(p);
  } else {
    var m=document.createElement('div'); m.className='msg'; m.textContent=L.text||''; list.appendChild(m);
  }
}

function findActive(t){
  var lo=-1;
  for(var i=0;i<rows.length;i++){ if(rows[i].t<=t) lo=i; else break; }
  return lo;
}
// Litery (spany) powstają tylko dla aktywnej linijki - reszta to zwykły tekst, więc strona jest lekka nawet przy długich tekstach.
function wake(row){
  if(row.sp||!row.a.length) return;
  row.el.innerHTML=''; row.sp=[];
  for(var k=0;k<row.a.length;k++){ var sp=document.createElement('span'); sp.textContent=row.a[k]; sp.style.opacity='0.38'; sp._q=0; row.el.appendChild(sp); row.sp.push(sp); }
}
function sleep(row){ if(row.sp){ row.el.textContent=row.txt; row.sp=null; } }
function follow(y){
  if(y<0) y=0;
  targetY=y;
  var el=$('lyr');
  tw={from:el.scrollTop,to:y,t0:now(),d:560};
}
function setActive(idx){
  active=idx;
  for(var i=0;i<rows.length;i++){ if(i!==idx&&rows[i].el.className!=='line'){ rows[i].el.className='line'; } }
  if(idx>=0){
    rows[idx].el.className='line on';
    if(rows[idx-1]) rows[idx-1].el.className='line n1';
    if(rows[idx+1]) rows[idx+1].el.className='line n1';
    var h=$('lyr').clientHeight;
    var y=rows[idx].el.offsetTop-h*0.30;
    if(now()>userUntil) follow(y); else { targetY=y<0?0:y; userMoved=true; }
  }
}
function paint(row,t){
  if(!row.sp) return;
  for(var k=0;k<row.sp.length;k++){
    var p=clamp((t-row.c[k])/row.f[k]); var e=p*p*(3-2*p); var q=Math.round(e*12)/12;
    var sp=row.sp[k];
    if(sp._q!==q){ sp._q=q; sp.style.opacity=(0.38+0.62*q).toFixed(2); }
  }
}
function userTouch(){ userUntil=now()+5000; userMoved=true; tw=null; }
function frame(){
  var n=now();
  if(tw){
    var p=clamp((n-tw.t0)/tw.d), e=1-Math.pow(1-p,3);
    $('lyr').scrollTop=tw.from+(tw.to-tw.from)*e;
    if(p>=1) tw=null;
  } else if(userMoved && n>userUntil && rows.length && active>=0 && !document.body.className.match(/nolyr/)){
    userMoved=false; follow(targetY);      // po kilku sekundach bez dotyku tekst sam wraca do śpiewanej linijki
  }
  if(n-lastPaint>=30){
    lastPaint=n;
    if(S&&L&&L.kind==='synced'&&rows.length&&!document.body.className.match(/nolyr/)){
      var t=pos(), idx=findActive(t);
      if(idx!==active) setActive(idx);
    }
    if(S&&!S.radio&&S.dur>0){ $('fill').style.width=(clamp(pos()/S.dur)*100)+'%'; } else { $('fill').style.width='0'; }
  }
  if(window.requestAnimationFrame) window.requestAnimationFrame(frame); else setTimeout(frame,33);
}

function syncAudio(){
  if(!soundOn||!S) return;
  if(!S.audio){ if(!au.paused) au.pause(); return; }
  if(au.getAttribute('data-src')!==S.audio){ au.setAttribute('data-src',S.audio); au.src=S.audio; try{au.load();}catch(e){} }
  if(S.radio){
    if(S.playing){ if(au.paused) tryPlay(); } else if(!au.paused){ au.pause(); }
    return;
  }
  var want=pos();
  if(S.playing){
    if(au.paused){ try{au.currentTime=want;}catch(e){} tryPlay(); }
    else if(Math.abs(au.currentTime-want)>1.2){ try{au.currentTime=want;}catch(e){} }
  } else if(!au.paused){ au.pause(); }
}
au.addEventListener('playing',function(){ $('tap').className='ov'; if(soundOn) $('st').textContent=''; });
au.addEventListener('error',function(){ if(soundOn&&au.getAttribute('data-src')) $('st').textContent='Nie mogę wczytać dźwięku z telefonu (sprawdź, czy to ta sama sieć Wi-Fi).'; });
au.addEventListener('loadedmetadata',function(){ if(S&&!S.radio&&S.audio&&au.getAttribute('data-src')===S.audio){ try{au.currentTime=pos();}catch(e){} } });

function setSound(on){
  soundOn=on;
  var b=$('bsound');
  b.className=on?'ib on':'ib';
  if(on){
    // Odtwarzanie musi zacząć się z kliknięcia, inaczej przeglądarka je zablokuje.
    if(S&&S.audio){ au.setAttribute('data-src',S.audio); au.src=S.audio; try{au.currentTime=S.radio?0:pos();}catch(e){} }
    else { au.src=SILENT; }
    tryPlay();
    cmd('mute','?on=1');
  } else {
    au.pause(); cmd('mute','?on=0');
  }
}
function setLyrics(show){
  document.body.className=show?'':'nolyr';
  $('btxt').className=show?'ib on':'ib';
  try{ localStorage.setItem('mp_lyr',show?'1':'0'); }catch(e){}
  if(show){ userMoved=true; userUntil=0; }
}
function leave(){
  if(left) return;
  left=true;
  if(soundOn){ au.pause(); soundOn=false; }
  cmd('mute','?on=0');
  clearInterval(timer);
  $('start').className='ov';
  $('bye').className='ov show';
  try{ window.close(); }catch(e){}
}
$('bsound').onclick=function(){ setSound(!soundOn); };
$('btxt').onclick=function(){ setLyrics(document.body.className.indexOf('nolyr')>=0); };
$('bexit').onclick=leave;
$('again').onclick=function(){ location.reload(); };
$('bplay').onclick=function(){ cmd('toggle'); };
$('bnext').onclick=function(){ cmd('next'); };
$('bprev').onclick=function(){ cmd('prev'); };
$('gosound').onclick=function(){ $('start').className='ov'; setSound(true); cmd('play'); };
$('taptap').onclick=function(){ $('tap').className='ov'; tryPlay(); };
$('goquiet').onclick=function(){ $('start').className='ov'; };
var lyrEl=$('lyr');
lyrEl.addEventListener('touchstart',userTouch);
lyrEl.addEventListener('touchmove',userTouch);
lyrEl.addEventListener('wheel',userTouch);
lyrEl.addEventListener('mousedown',userTouch);
document.onkeydown=function(e){
  var k=e.keyCode;
  if(k===415||k===179||k===19){ cmd('toggle'); }          // przyciski multimedialne pilotów
  else if(k===417||k===176){ cmd('next'); }
  else if(k===412||k===177){ cmd('prev'); }
  else if(k===27||k===10009||k===461||k===8){ leave(); }  // Esc / Wstecz (Samsung, LG)
  else if(k===38||k===40){ userTouch(); lyrEl.scrollTop+=(k===40?1:-1)*lyrEl.clientHeight*0.4; }
};
window.onbeforeunload=function(){ if(soundOn) cmd('mute','?on=0'); };
setIcons();
var showL=true; try{ showL=localStorage.getItem('mp_lyr')!=='0'; }catch(e){}
setLyrics(showL);
setSound(false);
$('gosound').focus();
timer=setInterval(poll,600); poll(); frame();
})();
</script>
</body>
</html>
"""#
}
