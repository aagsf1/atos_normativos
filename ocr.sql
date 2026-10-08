alter table public.trt16_arquivos add column if not exists ocr_lease uuid, add column if not exists ocr_proxima timestamptz, add column if not exists ocr_tentativas integer not null default 0, add column if not exists ocr_erro text, add column if not exists texto_metodo text;
create or replace function public.trt16_ocr_claim() returns jsonb language plpgsql security invoker set search_path='' as $$
declare f public.trt16_arquivos; begin
select x.* into f from public.trt16_arquivos x join public.trt16_atos a on a.id=x.ato_id where a.em_escopo and x.texto_estado='ocr_pendente' and (x.ocr_proxima is null or x.ocr_proxima<now()) and x.ocr_tentativas<5 order by a.ano desc,a.numero desc,x.ordem limit 1 for update of x skip locked;
if f.id is null then return null; end if;
update public.trt16_arquivos set ocr_lease=gen_random_uuid(),ocr_proxima=now()+interval '20 minutes',ocr_tentativas=ocr_tentativas+1 where id=f.id returning * into f;
return jsonb_build_object('id',f.id,'url',f.url,'lease',f.ocr_lease); end $$;
revoke all on function public.trt16_ocr_claim() from public,anon,authenticated;grant execute on function public.trt16_ocr_claim() to service_role;
create or replace function public.trt16_ocr_save(arquivo bigint,lease uuid,conteudo text,normalizado text,erro text default null) returns boolean language plpgsql security invoker set search_path='' as $$
begin
if erro is null and length(trim(conteudo))<40 then raise exception 'OCR without sufficient text';end if;
update public.trt16_arquivos set texto_pdf=case when erro is null then conteudo else texto_pdf end,texto_busca=case when erro is null then normalizado else texto_busca end,texto_estado=case when erro is null then 'concluido' else 'ocr_pendente' end,texto_metodo=case when erro is null then 'ocr' else texto_metodo end,texto_atualizado=case when erro is null then now() else texto_atualizado end,ocr_erro=left(erro,300),ocr_lease=null,ocr_proxima=now()+interval '2 hours' where id=arquivo and ocr_lease=lease and ocr_proxima>now();
return found;end $$;
revoke all on function public.trt16_ocr_save(bigint,uuid,text,text,text) from public,anon,authenticated; grant execute on function public.trt16_ocr_save(bigint,uuid,text,text,text) to service_role;