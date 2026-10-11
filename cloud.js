'use strict';
(() => {
  const base='https://qoitgszoifrsaouxomye.supabase.co';
  const key='sb_publishable_pynXTXDJfuj3bAIAIdTzQw_z7vFjCh4';
  const sessionKey='ogawa-session-v1';
  let session=null,refreshing=null;
  try {session=JSON.parse(sessionStorage.getItem(sessionKey));} catch {}
  const status=document.querySelector('#login-status');
  function keep(data){session=data;try{sessionStorage.setItem(sessionKey,JSON.stringify(data));}catch{}}
  async function auth(path,body){const res=await fetch(base+'/auth/v1/'+path,{method:'POST',headers:{apikey:key,'Content-Type':'application/json'},body:JSON.stringify(body),signal:AbortSignal.timeout(20000)});const data=await res.json();if(!res.ok)throw new Error(data.error_description||data.msg||data.message||'ログインできませんでした');return data;}
  async function token(){if(!session)throw new Error('ログインしてください');if((session.expires_at||0)*1000<Date.now()+60000){if(!refreshing)refreshing=auth('token?grant_type=refresh_token',{refresh_token:session.refresh_token}).then(keep).finally(()=>refreshing=null);await refreshing;}return session.access_token;}
  async function request(path,options={}) {const access=await token();const res=await fetch(base+'/rest/v1/'+path,{...options,headers:{apikey:key,Authorization:'Bearer '+access,'Content-Type':'application/json',Prefer:'return=representation',...options.headers},signal:AbortSignal.timeout(20000)});const text=await res.text();let data;try{data=text?JSON.parse(text):null;}catch{throw new Error('サーバーの応答を読み取れませんでした');}if(!res.ok)throw new Error(data?.message||'通信できませんでした');return data;}
  const map=r=>({id:r.id,name:r.name,type:r.type,date:r.start_date,mentor:r.mentor,v:r.evaluations,updated:r.updated_at});
  const cloud=window.ogawaCloud={role:null,records:[],load:async()=>{const rows=await request('ogawa_staff?select=*&order=start_date.asc,id.asc');cloud.records=rows.map(map);return cloud.records;},
    add:async s=>{if(cloud.role!=='editor')throw new Error('閲覧専用です');const rows=await request('ogawa_staff',{method:'POST',body:JSON.stringify({name:s.name,type:s.type,start_date:s.date,mentor:s.mentor,evaluations:s.v})});if(rows.length!==1)throw new Error('登録できませんでした');return map(rows[0]);},
    update:async(s,index,value)=>{if(cloud.role!=='editor')throw new Error('閲覧専用です');const values=[...s.v];values[index]=value;const rows=await request('ogawa_staff?id=eq.'+encodeURIComponent(s.id)+'&updated_at=eq.'+encodeURIComponent(s.updated),{method:'PATCH',body:JSON.stringify({evaluations:values,updated_at:new Date().toISOString()})});if(rows.length!==1)throw new Error('他の担当者が更新しています。「再読み込み」で最新の評価を確認してください。');return map(rows[0]);}}
  async function start(){const members=await request('ogawa_members?select=role&user_id=eq.'+encodeURIComponent(session.user.id));if(members.length!==1)throw new Error('利用権限が未登録です。管理者に確認してください。');cloud.role=members[0].role;await cloud.load();document.querySelector('#account-role').textContent=cloud.role==='editor'?'閲覧・編集':'閲覧専用';document.querySelector('#login').hidden=true;document.querySelector('#application').hidden=false;document.querySelector('#login-form').reset();if(!document.querySelector('#app-script')){const script=document.createElement('script');script.id='app-script';script.src='app.js?v=sync1';script.onerror=()=>{status.textContent='アプリを読み込めませんでした。再読み込みしてください。';document.querySelector('#login').hidden=false;};document.body.append(script);}}
  document.querySelector('#login-form').onsubmit=async e=>{e.preventDefault();const button=e.target.querySelector('button');button.disabled=true;status.textContent='接続しています…';try{keep(await auth('token?grant_type=password',{email:e.target.email.value.trim(),password:e.target.password.value}));await start();status.textContent='';}catch(error){status.textContent=error.message;}finally{button.disabled=false;}};
  document.querySelector('#logout').onclick=async()=>{try{const access=await token();await fetch(base+'/auth/v1/logout',{method:'POST',headers:{apikey:key,Authorization:'Bearer '+access},signal:AbortSignal.timeout(5000)});}catch{}finally{session=null;try{sessionStorage.removeItem(sessionKey);}catch{}location.reload();}};
  async function recovery(params){
    const access=params.get('access_token'),refresh=params.get('refresh_token');
    history.replaceState(null,'',location.pathname+location.search);
    document.querySelector('#login').hidden=false;document.querySelector('#application').hidden=true;
    if(!access||!refresh){status.textContent='再設定リンクが無効です。メールを再送してください。';return;}
    try {
      const response=await fetch(base+'/auth/v1/user',{headers:{apikey:key,Authorization:'Bearer '+access},signal:AbortSignal.timeout(20000)});
      if(!response.ok)throw new Error('再設定リンクが期限切れです。メールを再送してください。');
      const user=await response.json();
      keep({access_token:access,refresh_token:refresh,expires_at:Date.now()/1000+Number(params.get('expires_in')||3600),user});
      const form=document.querySelector('#login-form');
      form.innerHTML='<label>新しいパスワード<input name="password" type="password" required minlength="12" autocomplete="new-password"></label><label>新しいパスワード（確認）<input name="confirm" type="password" required minlength="12" autocomplete="new-password"></label><button class="primary" type="submit">パスワードを変更</button>';
      status.textContent='12文字以上の新しいパスワードを設定してください。';
      form.onsubmit=async e=>{e.preventDefault();if(form.password.value!==form.confirm.value){status.textContent='確認用のパスワードが一致していません。';return;}
        const button=form.querySelector('button');button.disabled=true;
        try{const res=await fetch(base+'/auth/v1/user',{method:'PUT',headers:{apikey:key,Authorization:'Bearer '+await token(),'Content-Type':'application/json'},body:JSON.stringify({password:form.password.value}),signal:AbortSignal.timeout(20000)});const data=await res.json();if(!res.ok)throw new Error(data.msg||data.message||'パスワードを変更できませんでした');form.reset();session=null;sessionStorage.removeItem(sessionKey);location.replace(location.pathname+'?password_updated=1');}
        catch(error){status.textContent=error.message;}finally{button.disabled=false;}};
    }catch(error){status.textContent=error.message;}
  }
  const params=new URLSearchParams(location.hash.slice(1));
  if(params.get('type')==='recovery'){recovery(params);}
  else if(params.has('error')){history.replaceState(null,'',location.pathname);status.textContent='再設定リンクが無効または期限切れです。メールを再送してください。';}
  else if(session)start().catch(error=>{status.textContent=error.message;});
  else if(new URLSearchParams(location.search).has('password_updated'))status.textContent='パスワードを変更しました。新しいパスワードでログインしてください。';
})();
