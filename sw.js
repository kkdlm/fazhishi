const CACHE='app-3.1.48';
const CORE=['./','manifest.webmanifest','icon-192.png','icon-512.png','apple-touch-icon.png'];
self.addEventListener('install',e=>{
  e.waitUntil(caches.open(CACHE).then(c=>c.addAll(CORE).catch(()=>{})).then(()=>self.skipWaiting()));
});
self.addEventListener('activate',e=>{
  e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));
});
self.addEventListener('fetch',e=>{
  const r=e.request;
  if(r.method!=='GET') return;
  const url=new URL(r.url);
  if(url.origin!==location.origin) return;
  // 版本探测永远走网络，避免被缓存挡住
  if(url.pathname.endsWith('/version.json')) return;
  if(r.mode==='navigate'){
    e.respondWith((async()=>{
      const c=await caches.open(CACHE);
      const net=(async()=>{
        const res=await fetch(r,{cache:'no-store'});
        if(res&&res.ok) c.put('index.html',res.clone());
        return res;
      })();
      const hit=await c.match('index.html');
      if(!hit) return (await net) || new Response('offline',{status:503,headers:{'Content-Type':'text/plain;charset=utf-8'}});
      // 有缓存：先给缓存秒开，同时后台拉新版写回，下次打开即为新版
      net.catch(()=>{});
      return hit;
    })());
    return;
  }
  e.respondWith(caches.match(r).then(c=>c||fetch(r).then(res=>{
    if(res&&res.ok&&!url.pathname.endsWith('.html')){ const cl=res.clone(); caches.open(CACHE).then(cc=>cc.put(r,cl)); }
    return res;
  }).catch(()=>c)));
});
