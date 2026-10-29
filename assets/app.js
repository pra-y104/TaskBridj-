const sb = supabase.createClient(CONFIG.SUPABASE_URL, CONFIG.SUPABASE_ANON_KEY);
const HOME = {participant:'participant.html', business:'business.html', admin:'admin.html'};
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const naira = n => '₦' + Number(n||0).toLocaleString('en-NG');
function toast(msg){const t=document.createElement('div');t.className='toast';t.textContent=msg;document.body.appendChild(t);setTimeout(()=>t.remove(),3200)}
async function getProfile(){
  const {data:{session}} = await sb.auth.getSession(); if(!session) return null;
  const {data} = await sb.from('profiles').select('*').eq('id',session.user.id).single(); return data;
}
async function guard(role){
  const p = await getProfile();
  if(!p){location.href='login.html';return null}
  if(p.role!==role){location.href=HOME[p.role];return null}
  return p;
}
async function logout(){await sb.auth.signOut();location.href='index.html'}
function navbar(p){
  return `<div class="nav"><div class="nav-in"><a class="brand" href="index.html"><img src="assets/logo.svg" alt="">TaskBridj</a>
  <div class="row" style="gap:14px"><span style="color:var(--muted);font-size:14px">${esc(p.full_name||'')}</span><button class="btn btn-out btn-sm" onclick="logout()">Log out</button></div></div></div>`;
}
