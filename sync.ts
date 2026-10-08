// Coleta em lotes. Credenciais administrativas ficam somente no ambiente da Edge Function.
const source = 'https://bibliotecadigital.trt16.jus.br';
const scopes = ['fb1166f6-d480-41b0-a09b-26b7f63b2c55','0bd21984-5ce9-4b34-9040-052b857ad0c9'];
const base = Deno.env.get('SUPABASE_URL')!;
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const headers = {apikey:key, Authorization:`Bearer ${key}`, 'Content-Type':'application/json'};
async function db(path:string,body?:unknown) {
 const r=await fetch(base+'/rest/v1/'+path,{method:body===undefined?'GET':'POST',headers,body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
 if(!r.ok)throw new Error('Database HTTP '+r.status+': '+(await r.text()).slice(0,300));
 const t=await r.text(); return t?JSON.parse(t):null;
}
async function official(url:string) {
 if(!url.startsWith(source+'/server/api/'))throw new Error('Unexpected source URL');
 const r=await fetch(url,{headers:{Accept:'application/json'},signal:AbortSignal.timeout(12000)});
 if(!r.ok)throw new Error('Tribunal HTTP '+r.status);
 return await r.json();
}
async function list(url:string,kind:string) {
 const all:any[]=[];let next:string|undefined=url;
 while(next) { const d=await official(next);all.push(...(d._embedded?.[kind]||[]));next=d._links?.next?.href; }
 return all;
}
const clean=(s:string)=>s.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase();
const meta=(i:any,k:string)=>(i.metadata?.[k]||[]).map((x:any)=>x.value).join('; ');
Deno.serve(async(req)=>{
 if(req.method!=='POST')return new Response('Method not allowed',{status:405});
 const token=req.headers.get('x-sync-token');if(!token)return new Response('Unauthorized',{status:401});
 const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(token)))).map(x=>x.toString(16).padStart(2,'0')).join('');
 let claim:any;
 try {claim=await db('rpc/trt16_sync_claim',{token_digest:hash});}catch{return new Response('Unauthorized',{status:401});}
 if(!claim)return Response.json({status:'idle'});
 try {
 const u=source+'/server/api/discover/search/objects?'+new URLSearchParams({scope:scopes[claim.colecao],'f.anoMateria':claim.ano+',equals',size:'25',page:String(claim.pagina),sort:'dc.date.issued,DESC'});
 const data=await official(u), search=data._embedded?.searchResult;
 if(!search?.page)throw new Error('Invalid discovery response');
 const items=(search._embedded?.objects||[]).map((o:any)=>o._embedded?.indexableObject).filter(Boolean);
 const ids=items.map((i:any)=>i.uuid).join(',');
 const existing=ids?await db('trt16_atos?select=fonte_uuid,fonte_modificado,trt16_arquivos(id)&fonte_uuid=in.('+ids+')'):[];
 const known=new Map(existing.map((i:any)=>[i.fonte_uuid,{modified:i.fonte_modificado,files:i.trt16_arquivos?.length||0}]));
 const atos:any[]=[],files:any[]=[];let ignored=0;
 let cursor=0;
 async function work(){while(cursor<items.length){const i=items[cursor++];
 const title=meta(i,'dc.title')||i.name;
 const match=title.match(/(\d+)\s*\/\s*(\d{4})/);
 const number=Number(meta(i,'local.identifier.number')||match?.[1]);
 const year=Number(meta(i,'local.identifier.year')||match?.[2]);
 if(!number||year!==claim.ano||i.withdrawn){ignored++;continue;}
 const previous:any=known.get(i.uuid); if(previous?.modified===i.lastModified && previous.files>0)continue;
 const abstract=meta(i,'dc.description.abstract')||meta(i,'dc.description')||'Ementa não informada no catálogo oficial.';
 const author=meta(i,'dc.contributor.author')||null;
 const issued=meta(i,'dc.date.issued').slice(0,10);
 const bundles=await list(i._links.bundles.href+'?size=100','bundles');
 const itemFiles:any[]=[];
 for(const bundle of bundles.filter((b:any)=>b.name==='ORIGINAL')) {
 const streams=await list(bundle._links.bitstreams.href+'?size=100','bitstreams');
 for(const stream of streams){
 const name=stream.name||meta(stream,'dc.title')||'Documento PDF';
 if(!/\.pdf$/i.test(name) && !/\.pdf$/i.test(meta(stream,'dc.source'))) { const format=await official(stream._links.format.href);if(format.mimetype!=='application/pdf')continue; }
 const description=meta(stream,'dc.description');
 const norm=clean(name+' '+description);
 const category=/consolidad|compilad/.test(norm)?'compilacao':/texto principal|original/.test(norm)?'original':/anexo/.test(norm)?'anexo':'nao_classificado';
 itemFiles.push({fonte_uuid:i.uuid,url:source+'/server/api/core/bitstreams/'+stream.uuid+'/content',nome:name,categoria:category,descricao:description||null,ordem:itemFiles.length});
 }
 }
 atos.push({tipo:claim.colecao===0?'Portaria':'Resolução',numero:number,ano:year,titulo:title,data_catalogo:/^\d{4}-\d{2}-\d{2}$/.test(issued)?issued:null,autor:author,resumo:abstract,origem:source+'/entities/publication/'+i.uuid+'/full',campo_busca:clean(title+' '+(author||'')+' '+abstract),fonte_uuid:i.uuid,fonte_modificado:i.lastModified});files.push(...itemFiles);
 }}
 await Promise.all([work(),work(),work()]);
 let nextYear=claim.ano,nextCollection=claim.colecao,nextPage=claim.pagina+1;
 if(nextPage>=search.page.totalPages){nextPage=0;nextCollection++;if(nextCollection>1){nextCollection=0;nextYear--;}}
 const done=nextYear<1989;
 await db('rpc/trt16_sync_save',{lote:atos,arquivos:files,claim_id:claim.lease_id,proximo_ano:nextYear,proxima_colecao:nextCollection,proxima_pagina:nextPage,terminou:done,ignorados_lote:ignored});
 return Response.json({updated:atos.length,pdfs:files.length,year:claim.ano,collection:claim.colecao,page:claim.pagina,done});
 }catch(e){
 const message=e instanceof Error?e.message:String(e);
 await db('rpc/trt16_sync_error',{claim_id:claim.lease_id,mensagem:message}).catch(()=>{});
 return Response.json({error:message},{status:502});
 }
});
