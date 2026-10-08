create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
alter table public.trt16_atos add column if not exists fonte_uuid uuid;
alter table public.trt16_atos add column if not exists fonte_modificado text;
create unique index if not exists trt16_fonte_uuid on public.trt16_atos(fonte_uuid);
create table public.trt16_base (
 id integer primary key check(id=1), ultima_atualizacao timestamptz,
 ultima_coleta_completa timestamptz, estado text not null default 'aguardando', ano_em_coleta integer
);
insert into public.trt16_base(id,ultima_atualizacao,estado) values(1,now(),'aguardando');
alter table public.trt16_base enable row level security;
revoke all on public.trt16_base from anon,authenticated;
grant select on public.trt16_base to anon,authenticated;
create policy base_leitura on public.trt16_base for select to anon,authenticated using(true);
create table public.trt16_sync (
 id integer primary key check(id=1), token_hash text not null,
 ano integer not null default 2026, colecao integer not null default 0, pagina integer not null default 0,
 ativo boolean not null default true, lease_until timestamptz, lease_id uuid,
 falhas integer not null default 0, ultimo_erro text, inicio timestamptz default now(), ignorados integer default 0
);
alter table public.trt16_sync enable row level security;
revoke all on public.trt16_sync from public,anon,authenticated;
grant all on public.trt16_sync,public.trt16_base to service_role;
do $$ declare token text := encode(extensions.gen_random_bytes(32),'hex'); begin
 perform vault.create_secret(token,'trt16_sync_token');
 insert into public.trt16_sync(id,token_hash) values(1,encode(extensions.digest(token,'sha256'),'hex'));
end $$;

create function public.trt16_sync_claim(token_digest text) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare s public.trt16_sync; begin
 select * into s from public.trt16_sync where id=1 for update;
 if s.token_hash<>token_digest then raise exception 'unauthorized'; end if;
 if not s.ativo or s.lease_until>now() then return null; end if;
 update public.trt16_sync set lease_until=now()+interval '3 minutes',lease_id=gen_random_uuid() where id=1 returning * into s;
 return to_jsonb(s)-'token_hash';
end $$;
revoke all on function public.trt16_sync_claim(text) from public,anon,authenticated;
grant execute on function public.trt16_sync_claim(text) to service_role;

create function public.trt16_sync_save(lote jsonb, arquivos jsonb, claim_id uuid, proximo_ano integer, proxima_colecao integer, proxima_pagina integer, terminou boolean, ignorados_lote integer)
returns void language plpgsql security invoker set search_path='' as $$
declare a jsonb; f jsonb; ato bigint; begin
 perform 1 from public.trt16_sync where id=1 and lease_id=claim_id and lease_until>now() for update;
 if not found then raise exception 'lease expired'; end if;
 for a in select value from jsonb_array_elements(lote) loop
 insert into public.trt16_atos(tipo,numero,ano,titulo,data_catalogo,autor,resumo,origem,coleta,campo_busca,fonte_uuid,fonte_modificado,pdf_url,pdf_observacao)
 values(a->>'tipo',(a->>'numero')::int,(a->>'ano')::int,a->>'titulo',nullif(a->>'data_catalogo','')::date,a->>'autor',a->>'resumo',a->>'origem',current_date,a->>'campo_busca',(a->>'fonte_uuid')::uuid,a->>'fonte_modificado',null,null)
 on conflict(tipo,numero,ano) do update set titulo=excluded.titulo,data_catalogo=excluded.data_catalogo,autor=excluded.autor,resumo=excluded.resumo,origem=excluded.origem,coleta=excluded.coleta,campo_busca=excluded.campo_busca,fonte_uuid=excluded.fonte_uuid,fonte_modificado=excluded.fonte_modificado;
 end loop;
 for f in select value from jsonb_array_elements(arquivos) loop
 select id into ato from public.trt16_atos where fonte_uuid=(f->>'fonte_uuid')::uuid;
 insert into public.trt16_arquivos(ato_id,url,nome,categoria,descricao,ordem,coleta)
 values(ato,f->>'url',f->>'nome',f->>'categoria',f->>'descricao',(f->>'ordem')::int,current_date)
 on conflict(url) do update set ato_id=excluded.ato_id,nome=excluded.nome,categoria=excluded.categoria,descricao=excluded.descricao,ordem=excluded.ordem,coleta=excluded.coleta;
 end loop;
 update public.trt16_sync set ano=proximo_ano,colecao=proxima_colecao,pagina=proxima_pagina,ativo=not terminou,lease_until=null,lease_id=null,falhas=0,ultimo_erro=null,ignorados=ignorados+ignorados_lote where id=1;
 update public.trt16_base set ultima_atualizacao=case when jsonb_array_length(lote)>0 then now() else ultima_atualizacao end,
 ultima_coleta_completa=case when terminou then now() else ultima_coleta_completa end,
 estado=case when terminou then 'concluida' else 'em_andamento' end,ano_em_coleta=case when terminou then null else proximo_ano end where id=1;
end $$;
revoke all on function public.trt16_sync_save(jsonb,jsonb,uuid,integer,integer,integer,boolean,integer) from public,anon,authenticated;
grant execute on function public.trt16_sync_save(jsonb,jsonb,uuid,integer,integer,integer,boolean,integer) to service_role;

create function public.trt16_sync_error(claim_id uuid,mensagem text) returns void
language sql security invoker set search_path='' as $$
 update public.trt16_sync set lease_until=now()+interval '10 minutes',lease_id=null,falhas=falhas+1,ultimo_erro=left(mensagem,500),ativo=(falhas<4) where id=1 and lease_id=claim_id;
 update public.trt16_base set estado='falha' where id=1;
$$;
revoke all on function public.trt16_sync_error(uuid,text) from public,anon,authenticated;
grant execute on function public.trt16_sync_error(uuid,text) to service_role;

create schema if not exists trt16_interno;
revoke all on schema trt16_interno from public,anon,authenticated;
create or replace function trt16_interno.dispatch() returns void language plpgsql security invoker set search_path='' as $$
begin
 if exists(select 1 from public.trt16_sync where id=1 and ativo and (lease_until is null or lease_until<now())) then
 perform net.http_post(url:='https://itobvfemswylcawdydrz.supabase.co/functions/v1/trt16-sync',
 headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='trt16_sync_anon_jwt'),'x-sync-token',(select decrypted_secret from vault.decrypted_secrets where name='trt16_sync_token')),
 body:='{}'::jsonb,timeout_milliseconds:=120000);
 end if;
end $$;
revoke all on function trt16_interno.dispatch() from public,anon,authenticated;

select cron.schedule('trt16-worker','* * * * *','select trt16_interno.dispatch();');
select cron.schedule('trt16-diario','0 6 * * *',$cron$
 update public.trt16_sync set ano=extract(year from now())::int,colecao=0,pagina=0,ativo=true,lease_until=null,lease_id=null,falhas=0,inicio=now() where id=1 and not ativo;
 update public.trt16_base set estado='em_andamento' where id=1 and exists(select 1 from public.trt16_sync where id=1 and ativo);
$cron$);

-- Antes de instalar em outro projeto, criar no Vault trt16_sync_anon_jwt com a chave anon JWT.
