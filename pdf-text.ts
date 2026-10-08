import {getDocument} from "npm:pdfjs-dist@4.10.38/legacy/build/pdf.mjs";
import {WorkerMessageHandler} from "npm:pdfjs-dist@4.10.38/legacy/build/pdf.worker.mjs";
(globalThis as any).pdfjsWorker={WorkerMessageHandler};
const base=Deno.env.get('SUPABASE_URL')!,key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
async function rpc(name:string,body:unknown){const r=await fetch(base+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:key,Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify(body)});if(!r.ok)throw Error('Database '+r.status+' '+(await r.text()).slice(0,200));const t=await r.text();return t?JSON.parse(t):null;}
Deno.serve(async req=>{
if(req.method!=='POST')return new Response('Method not allowed',{status:405});
const token=req.headers.get('x-sync-token');if(!token)return new Response('Unauthorized',{status:401});
const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(token)))).map(x=>x.toString(16).padStart(2,'0')).join('');
let f;try{f=await rpc('trt16_pdf_claim',{token_digest:hash});}catch{return new Response('Unauthorized',{status:401});}
if(!f)return Response.json({status:'idle'});
try{
if(!/^https:\/\/bibliotecadigital\.trt16\.jus\.br\/server\/api\/core\/bitstreams\/[0-9a-f-]{36}\/content$/i.test(f.url))throw Error('Invalid PDF URL');
const r=await fetch(f.url,{signal:AbortSignal.timeout(40000)});if(!r.ok)throw Error('Biblioteca HTTP '+r.status);
const bytes=new Uint8Array(await r.arrayBuffer());if(bytes.length>15000000)throw Error('PDF exceeds 15 MB');
const pdf=await getDocument({data:bytes,isEvalSupported:false,disableFontFace:true,useSystemFonts:false}).promise;
let text='';for(let n=1;n<=pdf.numPages;n++){const page=await pdf.getPage(n);const data=await page.getTextContent();text+=data.items.map((i:any)=>i.str||'').join(' ')+'\n';page.cleanup();}
await pdf.destroy();
const normalized=text.normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^\p{L}\p{N}_]+/gu,' ');
const state=text.trim().length>=40?'concluido':'ocr_pendente';
await rpc('trt16_pdf_save',{arquivo:f.id,lease:f.lease,conteudo:text,normalizado:normalized,estado:state});
return Response.json({id:f.id,status:state,characters:text.length});
}catch(e){const message=e instanceof Error?e.message:String(e);await rpc('trt16_pdf_save',{arquivo:f.id,lease:f.lease,conteudo:null,normalizado:null,estado:'erro',erro:message});return Response.json({id:f.id,error:message},{status:502});}
});