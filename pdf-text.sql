alter table public.trt16_arquivos add column if not exists texto_pdf text, add column if not exists texto_busca text, add column if not exists texto_estado text not null default 'pendente', add column if not exists texto_atualizado timestamptz, add column if not exists texto_tentativas integer not null default 0, add column if not exists texto_erro text, add column if not exists texto_proxima timestamptz, add column if not exists texto_lease uuid;
create index if not exists trt16_pdf_texto_gin on public.trt16_arquivos using gin(to_tsvector('simple',texto_busca));
create or replace function public.trt16_pdf_claim(token_digest text) returns jsonb language plpgsql security invoker set search_path='' as $$
declare f public.trt16_arquivos; begin
 if not exists(select 1 from public.trt16_sync where id=1 and token_hash=token_digest) then raise exception 'unauthorized'; end if;
 select x.* into f from public.trt16_arquivos x join public.trt16_atos a on a.id=x.ato_id where a.em_escopo and (x.texto_estado='pendente' or (x.texto_estado in ('erro','processando') and x.texto_proxima<now() and x.texto_tentativas<5)) order by a.ano desc,a.numero desc,x.ordem limit 1 for update of x skip locked;
 if f.id is null then return null; end if;
 update public.trt16_arquivos set texto_estado='processando',texto_lease=gen_random_uuid(),texto_tentativas=texto_tentativas+1,texto_proxima=now()+interval '5 minutes' where id=f.id returning * into f;
 return jsonb_build_object('id',f.id,'url',f.url,'lease',f.texto_lease); end $$;
revoke all on function public.trt16_pdf_claim(text) from public,anon,authenticated; grant execute on function public.trt16_pdf_claim(text) to service_role;
create or replace function public.trt16_pdf_save(arquivo bigint,lease uuid,conteudo text,normalizado text,estado text,erro text default null) returns void language plpgsql security invoker set search_path='' as $$
begin
 if estado not in ('concluido','ocr_pendente','erro') then raise exception 'Invalid status'; end if;
 update public.trt16_arquivos set texto_pdf=conteudo,texto_busca=normalizado,texto_estado=estado,texto_atualizado=now(),texto_erro=left(erro,300),texto_proxima=now()+interval '30 minutes',texto_lease=null where id=arquivo and texto_lease=lease;
end $$;
revoke all on function public.trt16_pdf_save(bigint,uuid,text,text,text,text) from public,anon,authenticated; grant execute on function public.trt16_pdf_save(bigint,uuid,text,text,text,text) to service_role;
create or replace function trt16_interno.pdf_dispatch() returns void language plpgsql security invoker set search_path='' as $$
begin
perform net.http_post(url:='https://itobvfemswylcawdydrz.supabase.co/functions/v1/trt16-pdf',
headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='trt16_sync_anon_jwt'),'x-sync-token',(select decrypted_secret from vault.decrypted_secrets where name='trt16_sync_token')),body:='{}'::jsonb,timeout_milliseconds:=120000);
end $$;
revoke all on function trt16_interno.pdf_dispatch() from public,anon,authenticated;
select cron.schedule('trt16-pdf-worker','* * * * *','select trt16_interno.pdf_dispatch();');