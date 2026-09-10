/* HouseHold service worker
   Twee taken:
   1. de app installeerbaar maken op het startscherm
   2. iconen en lettertypes snel laden

   Let op: de pagina zelf wordt bewust NIET uit de cache geserveerd zolang
   er internet is. Anders zou je na een upload naar GitHub nog dagenlang
   de oude versie zien. Verhoog VERSIE bij een grote wijziging; de oude
   cache wordt dan opgeruimd.
*/

const VERSIE = 'household-v1';

const SCHIL = [
  './',
  './index.html',
  './icons/beeldmerk-transparant.png',
  './icons/favicon-32.png',
  './icons/apple-touch-icon-180.png',
  './icons/icon-192.png',
  './icons/icon-512.png'
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(VERSIE)
      // afzonderlijk toevoegen: ontbreekt er één bestand, dan mislukt niet alles
      .then(c => Promise.allSettled(SCHIL.map(u => c.add(u))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(namen => Promise.all(namen.filter(n => n !== VERSIE).map(n => caches.delete(n))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if(req.method !== 'GET') return;

  const url = new URL(req.url);

  // Supabase nooit cachen: dat zijn live gegevens en inloggegevens
  if(url.hostname.endsWith('supabase.co')) return;

  // De pagina zelf: eerst het net, cache alleen als vangnet bij geen verbinding
  if(req.mode === 'navigate'){
    e.respondWith(
      fetch(req)
        .then(res => {
          const kopie = res.clone();
          caches.open(VERSIE).then(c => c.put('./index.html', kopie));
          return res;
        })
        .catch(() => caches.match('./index.html'))
    );
    return;
  }

  // Iconen, lettertypes en de Supabase-bibliotheek: eerst de cache
  e.respondWith(
    caches.match(req).then(hit => hit || fetch(req).then(res => {
      if(res.ok && (url.origin === location.origin || url.hostname.endsWith('gstatic.com'))){
        const kopie = res.clone();
        caches.open(VERSIE).then(c => c.put(req, kopie));
      }
      return res;
    }).catch(() => hit))
  );
});
