import {createRemoteJWKSet,jwtVerify} from "npm:jose@6.1.0";
const jwks=createRemoteJWKSet(new URL('https://token.actions.githubusercontent.com/.well-known/jwks'));
const base=Deno.env.get('SUPABASE_URL')!,key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
async function rpc(name:string,body:unknown){const r=await fetch(base+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify(body)});if(!r.ok)throw Error('Database '+r.status);const t=await r.text();return t?JSON.parse(t):null;}
Deno.serve(async req=>{
if(req.method!=='POST')return new Response('Method not allowed',{status:405});
try{
const {payload}=await jwtVerify((req.headers.get('authorization')||'').replace(/^Bearer /,''),jwks,{issuer:'https://token.actions.githubusercontent.com',audience:'trt16-audit',algorithms:['RS256']});
if(payload.repository_id!=='1410539171'||payload.repository_owner_id!=='39031315'||payload.ref!=='refs/heads/main'||payload.workflow_ref!=='aagsf1/atos_normativos/.github/workflows/audit-pdfs.yml@refs/heads/main')throw Error('Wrong workflow');
}catch{return new Response('Unauthorized',{status:401});}
try{
const body=await req.json();
if(body.action==='claim')return Response.json(await rpc('trt16_auditoria_claim',{}));
if(body.action!=='save'||!Number.isSafeInteger(body.id)||!/^[-0-9a-f]{36}$/i.test(body.lease)||!body.result||JSON.stringify(body.result).length>12000)return new Response('Invalid request',{status:400});
return Response.json({saved:await rpc('trt16_auditoria_save',{item:body.id,claim:body.lease,resultado:body.result})});
}catch{return new Response('Processing failed',{status:500});}
});