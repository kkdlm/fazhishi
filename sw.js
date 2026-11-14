const CACHE='app-3.1.49';
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
    return j && j.version ? String(j.version) : null;
  }catch(e){ return null; }
}
async function cachedVer(c){
  try{
    const m=await c.match('v.json');
    if(!m) return null;
    const j=await m.json();
    return j && j.v ? String(j.v) : null;
  }catch(e){ return null; }
}
async function putIndex(c,res,v){
  await c.put('index.html',res.clone());
  await c.put('v.json',new Response(JSON.stringify({v:v||''}),{headers:{'Content-Type':'application/json'}}));
}

self.addEventListener('fetch',e=>{
  const r=e.request;
  if(r.method!=='GET') return;
  const url=new URL(r.url);
  if(url.origin!==location.origin) return;

  if(r.mode==='navigate'){
    e.respondWith((async()=>{
      const c=await caches.open(CACHE);
      // 版本感知：服务器版本与缓存记录不一致 → 必须走网络，不能给旧页面
      const [rv,lv,hit]=await Promise.all([remoteVer(),cachedVer(c),c.match('index.html')]);
      if(hit && rv && lv && rv===lv){
        // 版本一致，缓存秒开，后台顺带更新一次
        fetch(r,{cache:'no-store'}).then(async res=>{ if(res&&res.ok) await putIndex(c,res,rv); }).catch(()=>{});
        return hit;
      }
      try{
        const res=await fetch(r,{cache:'no-store'});
        if(res && res.ok){ await putIndex(c,res,rv); return res; }
        throw new Error('bad');
      }catch(err){
        if(hit) return hit;
        return new Response('offline',{status:503,headers:{'Content-Type':'text/plain;charset=utf-8'}});
      }
    })());
    return;
  }

  // version.json 永远走网络
  if(url.pathname.endsWith('/version.json')){
    e.respondWith(fetch(r,{cache:'no-store'}));
    return;
  }
  e.respondWith(caches.match(r).then(c=>c||fetch(r).then(res=>{
    if(res&&res.ok&&!url.pathname.endsWith('.html')){
      const cl=res.clone();
      caches.open(CACHE).then(cc=>cc.put(r,cl));
    }
    return res;
  }).catch(()=>c)));
});
