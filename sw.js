const CACHE='app-3.7.0-p29';
const CORE=['manifest.webmanifest','icon-192.png','icon-512.png','apple-touch-icon.png'];

self.addEventListener('install',e=>{
  e.waitUntil(caches.open(CACHE).then(c=>c.addAll(CORE).catch(()=>{})).then(()=>self.skipWaiting()));
});
self.addEventListener('activate',e=>{
  e.waitUntil((async()=>{
    const ks=await caches.keys();
    await Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k)));
    await self.clients.claim();
  })());
});

async function remoteVer(){
  try{
    const r=await fetch('version.json?ts='+Date.now(),{cache:'no-store'});
    if(!r.ok) return null;
    const j=await r.json();
    return j&&j.version?String(j.version):null;
  }catch(e){ return null; }
}
async function cachedVer(c){
  try{
    const m=await c.match('v.json');
    if(!m) return null;
    const j=await m.json();
    return j&&j.v?String(j.v):null;
  }catch(e){ return null; }
}
async function remember(c,res,v){
  try{ await c.put('index.html',res.clone()); }catch(e){}
  try{ await c.put('v.json',new Response(JSON.stringify({v:v||''}),{headers:{'Content-Type':'application/json'}})); }catch(e){}
}
function offlinePage(){
  return new Response('<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
   +'<title>暂时打不开</title><body style="font:16px/1.7 -apple-system,system-ui,sans-serif;padding:32px;background:#F6F5F0;color:#22302B">'
   +'<h2 style="font-size:18px">这一下没连上</h2><p>网络恢复了点下面按钮重开，已经缓存过的内容离线也能看。</p>'
   +'<button onclick="location.replace(location.pathname+\'?t=\'+Date.now())" style="margin-top:16px;padding:12px 20px;border:0;border-radius:10px;background:#2C4A3E;color:#fff;font-size:15px">重新打开</button>'
   +'</body>',{status:503,headers:{'Content-Type':'text/html;charset=utf-8'}});
}

self.addEventListener('fetch',e=>{
  const r=e.request;
  if(r.method!=='GET') return;
  const url=new URL(r.url);
  if(url.origin!==location.origin) return;
  // 管理后台（/admin/）不归 Service Worker 管，直接走网络，避免被缓存首页顶掉
  if(url.pathname==='/admin'||url.pathname.startsWith('/admin/')) return;

  if(r.mode==='navigate'){
    e.respondWith((async()=>{
      const c=await caches.open(CACHE);
      const hit=await c.match('index.html');
      // 先把网络请求抛出去，任何缓存操作都不挡它
      const net=fetch(r,{cache:'no-store'}).catch(()=>null);
      const [rv,lv]=await Promise.all([remoteVer(),cachedVer(c)]);
      if(hit && rv && lv && rv===lv){
        net.then(async res=>{ if(res&&res.ok) await remember(c,res,rv); }).catch(()=>{});
        return hit;
      }
      const res=await net;
      if(res&&res.ok){ await remember(c,res,rv); return res; }
      if(hit) return hit;
      return offlinePage();
    })());
    return;
  }

  if(url.pathname.endsWith('/version.json')){
    e.respondWith(fetch(r,{cache:'no-store'}).catch(()=>new Response('{}',{headers:{'Content-Type':'application/json'}})));
    return;
  }

  // 图片等静态资源：先缓存，再网络，并回填
  e.respondWith((async()=>{
    const c=await caches.open(CACHE);
    const hit=await c.match(r);
    if(hit) return hit;
    try{
      const res=await fetch(r,{cache:'no-store'});
      if(res&&res.ok){ try{ await c.put(r,res.clone()); }catch(e){} }
      return res;
    }catch(err){
      return new Response('',{status:504});
    }
  })());
});
