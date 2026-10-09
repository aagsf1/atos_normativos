create table public.trt16_auditorias (
 id uuid primary key default gen_random_uuid(),inicio timestamptz not null default now(),descricao text not null,estado text not null default 'em_andamento'
);
create table public.trt16_auditoria_itens (
 id bigint generated always as identity primary key,auditoria_id uuid not null references public.trt16_auditorias(id),ato_id bigint not null references public.trt16_atos(id),arquivo_id bigint references public.trt16_arquivos(id),
 cadastro jsonb not null,url text,categoria text,estado text not null default 'pendente',documento jsonb,evidencia text,metodo text,hash_evidencia text,motivo text,
 atualizado timestamptz,lease uuid,lease_ate timestamptz,tentativas integer not null default 0,
 unique nulls not distinct(auditoria_id,ato_id,arquivo_id)
);
create index trt16_auditoria_fila on public.trt16_auditoria_itens(auditoria_id,estado,id);
create table public.trt16_correcoes_verificadas (
 ato_id bigint primary key references public.trt16_atos(id),fonte_uuid uuid unique not null,tipo text not null check(tipo in ('Portaria','Resolução')),numero integer not null,ano integer not null,titulo text not null,
 evidencia_url text not null,evidencia text not null,verificado_por text not null,verificado_em timestamptz not null default now()
);
create table public.trt16_conflitos_correcao (
 id bigint generated always as identity primary key,ato_id bigint references public.trt16_atos(id),recebido jsonb not null,correcao jsonb not null,registrado timestamptz not null default now()
);
alter table public.trt16_auditorias enable row level security;
alter table public.trt16_auditoria_itens enable row level security;
alter table public.trt16_correcoes_verificadas enable row level security;
alter table public.trt16_conflitos_correcao enable row level security;
revoke all on public.trt16_auditorias,public.trt16_auditoria_itens,public.trt16_correcoes_verificadas,public.trt16_conflitos_correcao from public,anon,authenticated;
grant all on public.trt16_auditorias,public.trt16_auditoria_itens,public.trt16_correcoes_verificadas,public.trt16_conflitos_correcao to service_role;
grant usage,select on sequence public.trt16_auditoria_itens_id_seq,public.trt16_conflitos_correcao_id_seq to service_role;
create function public.trt16_preserva_correcao() returns trigger language plpgsql security invoker set search_path='' as $$
declare c public.trt16_correcoes_verificadas;begin
select * into c from public.trt16_correcoes_verificadas where fonte_uuid=new.fonte_uuid or (tg_op='UPDATE' and ato_id=new.id) limit 1;
if c.ato_id is not null then
if (new.tipo,new.numero,new.ano,new.titulo) is distinct from (c.tipo,c.numero,c.ano,c.titulo) then
insert into public.trt16_conflitos_correcao(ato_id,recebido,correcao) values(c.ato_id,jsonb_build_object('tipo',new.tipo,'numero',new.numero,'ano',new.ano,'titulo',new.titulo,'fonte_uuid',new.fonte_uuid),to_jsonb(c));
end if;
new.tipo:=c.tipo;new.numero:=c.numero;new.ano:=c.ano;new.titulo:=c.titulo;
new.campo_busca:=lower(translate(c.titulo||' '||coalesce(new.autor,'')||' '||coalesce(new.resumo,''),'ÁÀÂÃÉÊÍÓÔÕÚÜÇáàâãéêíóôõúüç','AAAAEEIOOOUUCaaaaeeiooouuc'));
end if;return new;end $$;
revoke all on function public.trt16_preserva_correcao() from public,anon,authenticated;
grant execute on function public.trt16_preserva_correcao() to service_role;
create trigger trt16_identidade_protegida before insert or update on public.trt16_atos for each row execute function public.trt16_preserva_correcao();
create function public.trt16_auditoria_claim() returns jsonb language plpgsql security invoker set search_path='' as $$
declare i public.trt16_auditoria_itens;begin
select * into i from public.trt16_auditoria_itens where estado='pendente' or (estado='processando' and lease_ate<now() and tentativas<3) order by (cadastro->>'ano')::int desc,id limit 1 for update skip locked;
if i.id is null then return null;end if;
update public.trt16_auditoria_itens set estado='processando',lease=gen_random_uuid(),lease_ate=now()+interval '15 minutes',tentativas=tentativas+1 where id=i.id returning * into i;
return jsonb_build_object('id',i.id,'lease',i.lease,'cadastro',i.cadastro,'url',i.url,'categoria',i.categoria,'texto',(select left(texto_pdf,6000) from public.trt16_arquivos where id=i.arquivo_id),'metodo_texto',(select texto_metodo from public.trt16_arquivos where id=i.arquivo_id));end $$;
create function public.trt16_auditoria_save(item bigint,claim uuid,resultado jsonb) returns boolean language plpgsql security invoker set search_path='' as $$
declare done boolean;begin
if resultado->>'estado' not in ('conferente_automatico','divergente','inconclusivo') then raise exception 'Estado inválido';end if;
update public.trt16_auditoria_itens set estado=resultado->>'estado',documento=resultado->'documento',evidencia=left(resultado->>'evidencia',2000),metodo=resultado->>'metodo',hash_evidencia=resultado->>'hash_evidencia',motivo=resultado->>'motivo',atualizado=now(),lease=null,lease_ate=null where id=item and lease=claim and lease_ate>now();
done:=found;
update public.trt16_auditorias a set estado='concluida' where not exists(select 1 from public.trt16_auditoria_itens i where i.auditoria_id=a.id and i.estado in ('pendente','processando'));
return done;end $$;
revoke all on function public.trt16_auditoria_claim(),public.trt16_auditoria_save(bigint,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.trt16_auditoria_claim(),public.trt16_auditoria_save(bigint,uuid,jsonb) to service_role;
do $$ declare run_id uuid;begin
insert into public.trt16_auditorias(descricao) values('Auditoria de identidade nos PDFs originais; importação suspensa; nenhuma correção automática') returning id into run_id;
insert into public.trt16_auditoria_itens(auditoria_id,ato_id,arquivo_id,cadastro,url,categoria,estado,motivo)
select run_id,a.id,f.id,jsonb_build_object('tipo',a.tipo,'numero',a.numero,'ano',a.ano,'titulo',a.titulo,'fonte_uuid',a.fonte_uuid),f.url,f.categoria,case when f.id is null then 'inconclusivo' else 'pendente' end,case when f.id is null then 'Registro sem PDF associado' end
from public.trt16_atos a left join public.trt16_arquivos f on f.ato_id=a.id where a.em_escopo;
end $$;