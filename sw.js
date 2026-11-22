const CACHE='app-4.3.1-p3';
const CORE=['manifest.webmanifest','icon-192.png','icon-512.png','apple-touch-icon.png'];

self.addEventListener('install',e=>{
  e.waitUntil(caches.open(CACHE).then(c=>c.addAll(CORE).catch(()=>{})).then(()=>self.skipWaiting()));
});
self.addEventListener('activate',e=>{
  e.waitUntil((async()=>{
    const ks=await caches.keys();
    await Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k)));
    /* 清掉历史上以 ?v=/&n= 为键存下的 app.html 碎片（每份 4.9MB） */
    try{
      const c=await caches.open(CACHE);
      const reqs=await c.keys();
      const base=new URL('app.html',self.location.href).href;
      await Promise.all(reqs.filter(q=>q.url.indexOf(base+'?')===0).map(q=>c.delete(q)));
    }catch(e){}
    await self.clients.claim();
  })());
});

/* 任何网络请求都加超时，绝不让「打开应用」一直挂着 */
function withTimeout(p,ms){
  let t;
  return Promise.race([
    p.catch(()=>null),
    new Promise(res=>{ t=setTimeout(()=>res(null),ms); })
  ]).then(v=>{ clearTimeout(t); return v; });
}
async function remoteVer(){
  const r=await withTimeout(fetch('version.json?ts='+Date.now(),{cache:'no-store'}),5000);
  if(!r||!r.ok) return null;
  try{ const j=await r.json();
    if(!j||!j.version) return null;
    return String(j.version)+(j.patch?('-p'+j.patch):'');
  }catch(e){ return null; }
}
async function cachedVer(c){
  try{
    const m=await c.match('v.json'); if(!m) return null;
    const j=await m.json(); return j&&j.v?String(j.v):null;
  }catch(e){ return null; }
}
async function remember(c,res,v){
  let size=0; try{ size=(await res.clone().blob()).size; }catch(e){}
  try{ await c.put('index.html',res.clone()); }catch(e){}
  try{ await c.put('v.json',new Response(JSON.stringify({v:v||'',s:size}),{headers:{'Content-Type':'application/json'}})); }catch(e){}
}
/* 缓存首页要自检：太小或与记录不符，说明存坏了，不能用 */
async function cacheOk(c,hit){
  try{
    const size=(await hit.clone().blob()).size;
    if(size < 6000) return false;          /* index.html 现在是几 KB 的启动壳 */
    const m=await c.match('v.json'); if(!m) return false;
    const j=await m.json();
    if(j && j.s && Math.abs(size-j.s) > 4096) return false;
    return true;
  }catch(e){ return false; }
}
/* 后台悄悄更新首页缓存，不参与本次响应 */
async function bgUpdate(c,req){
  try{
    const rv=await remoteVer();
    const lv=await cachedVer(c);
    if(rv && lv && rv===lv) return;                 // 版本一致，缓存就是最新
    const res=await withTimeout(fetch(req,{cache:'no-store'}),15000);
    if(res && res.ok) await remember(c,res,rv);
  }catch(e){}
}

function offlinePage(){
  return new Response('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
   +'<title>暂时打不开</title>'
   +'<body style="margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font:16px/1.75 -apple-system,system-ui,sans-serif;background:#F6F5F0;color:#22302B;padding:28px">'
   +'<div style="max-width:420px">'
   +'<div style="width:52px;height:52px;border-radius:9px;background:#B4483F;color:#FBF2E3;display:flex;align-items:center;justify-content:center;font-size:24px;font-weight:600">史</div>'
   +'<h2 style="font-size:19px;margin:16px 0 8px">现在没有网络，页面没打开</h2>'
   +'<p style="color:#5b6660;margin:0 0 6px">已缓存的内容离线也能看，正在等网络恢复后自动重试。</p>'
   +'<p style="color:#8a938d;font-size:13px;margin:0 0 18px">一直空白的话：把应用从后台清掉重新打开，或点下面按钮。</p>'
   +'<button id="b" style="padding:12px 22px;border:0;border-radius:10px;background:#2C4A3E;color:#fff;font-size:15px">重新打开</button>'
   +'<script>'
   +'var n=0;function go(){location.replace(location.pathname+"?t="+Date.now());}'
   +'document.getElementById("b").onclick=go;'
   +'var iv=setInterval(function(){n++;if(navigator.onLine){clearInterval(iv);go();}if(n>40)clearInterval(iv);},3000);'
   +'<\/script></div></body>',{status:503,headers:{'Content-Type':'text/html;charset=utf-8'}});
}

self.addEventListener('fetch',e=>{
  const r=e.request;
  if(r.method!=='GET') return;
  const url=new URL(r.url);
  if(url.origin!==location.origin) return;
  if(url.pathname==='/admin'||url.pathname.startsWith('/admin/')) return;

  if(r.mode==='navigate'){
    e.respondWith((async()=>{
      const c=await caches.open(CACHE);
      /* 手动更新（带 ?v=）必须走网络，否则永远拿回旧壳，看起来像「点了没反应」 */
      if(url.searchParams.has('v')){
        const fresh=await withTimeout(fetch(r,{cache:'no-store'}),12000);
        if(fresh && fresh.ok){ try{ await remember(c,fresh.clone(),await remoteVer()); }catch(err){} return fresh; }
        const h0=await c.match('index.html');
        return (h0 && await cacheOk(c,h0)) ? h0 : offlinePage();
      }
      const hit=await c.match('index.html');
      /* 有缓存就立即返回，不在响应链里等任何网络请求；缓存损坏则不用 */
      if(hit && await cacheOk(c,hit)){
        e.waitUntil(bgUpdate(c,r));
        return hit;
      }
      const res=await withTimeout(fetch(r,{cache:'no-store'}),9000);
      if(res && res.ok){
        try{ await remember(c,res.clone(),await remoteVer()); }catch(err){}
        return res;
      }
      return offlinePage();
    })());
    return;
  }

  if(url.pathname.endsWith('/version.json')){
    e.respondWith(withTimeout(fetch(r,{cache:'no-store'}),5000).then(x=>x||new Response('{}',{headers:{'Content-Type':'application/json'}})));
    return;
  }

  /* 完整正文体积大、首次下载慢，单独放宽超时并确保能缓存（离线/二次打开要用） */
  if(url.pathname.endsWith('/app.html')){
    e.respondWith((async()=>{
      const c=await caches.open(CACHE);
      const KEY=new URL('app.html',self.location.href).href;   /* 固定键，忽略 ?v=&n= */
      const hit=await c.match(KEY);
      if(hit){ try{ if((await hit.clone().blob()).size>1000000) return hit; }catch(err){} }
      const res=await withTimeout(fetch(r,{cache:'no-store'}),60000);
      if(res && res.ok){ try{ await c.put(KEY,res.clone()); }catch(err){} return res; }
      if(hit) return hit;
      return new Response('',{status:504});
    })());
    return;
  }

  e.respondWith((async()=>{
    const c=await caches.open(CACHE);
    const hit=await c.match(r);
    if(hit) return hit;
    const res=await withTimeout(fetch(r,{cache:'no-store'}),8000);
    if(res && res.ok){ try{ await c.put(r,res.clone()); }catch(err){} return res; }
    return new Response('',{status:504});
  })());
});
