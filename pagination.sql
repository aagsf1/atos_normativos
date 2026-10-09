create or replace function public.trt16_consulta_termos(q text) returns tsquery language plpgsql immutable security invoker set search_path='' as $$
declare token text; clean text; term text; alt text=''; grp text=''; allgroups text=''; begin
q:=translate(lower(left(coalesce(q,''),300)),'“”','""');
if (length(q)-length(replace(q,'"',''))) % 2 <> 0 then raise exception 'Feche as aspas da expressão pesquisada.' using errcode='22023'; end if;
for token in select m[1] from regexp_matches(q,'"[^"]*"|[^[:space:]"]+','g') m loop
if token in ('e','ou') then
 if alt<>'' then grp:=concat_ws(' | ',nullif(grp,''),'('||alt||')');alt:='';end if;
 if token='e' and grp<>'' then allgroups:=concat_ws(' & ',nullif(allgroups,''),'('||grp||')');grp:='';end if;
else
 clean:=regexp_replace(translate(token,'áàâãéêíóôõúüç','aaaaeeiooouuc'),'[^[:alnum:]_]+',' ','g');
 if left(token,1)='"' then term:=nullif(phraseto_tsquery('simple',clean)::text,'');
 else select string_agg(quote_literal(w)||':*',' & ') into term from regexp_split_to_table(trim(clean),'\s+') w where w<>''; end if;
 if term is not null then alt:=concat_ws(' & ',nullif(alt,''),'('||term||')');end if;
end if;
end loop;
if alt<>'' then grp:=concat_ws(' | ',nullif(grp,''),'('||alt||')');end if;
if grp<>'' then allgroups:=concat_ws(' & ',nullif(allgroups,''),'('||grp||')');end if;
return nullif(allgroups,'')::tsquery;end $$;
revoke all on function public.trt16_consulta_termos(text) from public;
grant execute on function public.trt16_consulta_termos(text) to anon,authenticated;

create or replace function public.trt16_pesquisar_pagina(q text default '',tipo_filtro text default '',ano_filtro integer default null,numero_filtro integer default null,pagina_num integer default 1,tamanho_pagina integer default 25)
returns jsonb language sql stable security invoker set search_path = '' as $$
 with termos as (select public.trt16_consulta_termos(q) as consulta), filtrados as (
 select a.* from public.trt16_atos a cross join termos t
 where a.em_escopo and (t.consulta is null or to_tsvector('simple',regexp_replace(a.campo_busca,'[^[:alnum:]_]+',' ','g')) @@ t.consulta or exists(select 1 from public.trt16_arquivos f where f.ato_id=a.id and f.texto_estado='concluido' and to_tsvector('simple',regexp_replace(a.campo_busca,'[^[:alnum:]_]+',' ','g')||' '||coalesce(f.texto_busca,'')) @@ t.consulta))
 and (tipo_filtro='' or a.tipo=tipo_filtro)
 and (ano_filtro is null or a.ano=ano_filtro)
 and (numero_filtro is null or a.numero=numero_filtro)
 ), contagem as (select count(*) as n from filtrados), limites as (
 select case when tamanho_pagina in (25,50,75,100) then tamanho_pagina else 25 end as tamanho
 ), paginacao as (
 select tamanho,greatest(1,least(greatest(1,coalesce(pagina_num,1)),greatest(1,ceil(n::numeric/tamanho)::int))) as atual,greatest(1,ceil(n::numeric/tamanho)::int) as paginas from limites cross join contagem
 ), pagina as (select * from filtrados order by ano desc,numero desc limit (select tamanho from paginacao) offset (select (atual-1)*tamanho from paginacao))
 select jsonb_build_object(
 'resultados',coalesce((select jsonb_agg((to_jsonb(p)-'campo_busca') || jsonb_build_object('arquivos',coalesce((select jsonb_agg((to_jsonb(f)-'texto_pdf'-'texto_busca'-'texto_lease'-'texto_erro'-'texto_proxima'-'texto_tentativas'-'ocr_lease'-'ocr_proxima'-'ocr_tentativas'-'ocr_erro') || jsonb_build_object('encontrado_no_pdf',exists(select 1 from termos t where t.consulta is not null and f.texto_estado='concluido' and to_tsvector('simple',f.texto_busca) @@ t.consulta)) order by f.ordem,f.id) from public.trt16_arquivos f where f.ato_id=p.id),'[]'::jsonb)) order by ano desc,numero desc) from pagina p),'[]'::jsonb),
 'encontrados',(select count(*) from filtrados),
 'pagina',(select atual from paginacao),'paginas',(select paginas from paginacao),'tamanho_pagina',(select tamanho from paginacao),
 'pdfs_indexados',(select count(*) from public.trt16_arquivos f join public.trt16_atos a on a.id=f.ato_id where a.em_escopo and f.texto_estado='concluido'),
 'pdfs_total',(select count(*) from public.trt16_arquivos f join public.trt16_atos a on a.id=f.ato_id where a.em_escopo),
 'total',(select count(*) from public.trt16_atos where em_escopo),
 'quantidades_por_tipo',coalesce((select jsonb_agg(jsonb_build_object('tipo',tipo,'quantidade',quantidade) order by tipo) from (select tipo,count(*) quantidade from public.trt16_atos where em_escopo group by tipo) t),'[]'::jsonb),
 'base',(select to_jsonb(b)-'id' from public.trt16_base b where id=1),
 'anos',coalesce((select jsonb_agg(ano order by ano desc) from (select distinct ano from public.trt16_atos where em_escopo) y),'[]'::jsonb))
$$;
revoke all on function public.trt16_pesquisar_pagina(text,text,integer,integer,integer,integer) from public;
grant execute on function public.trt16_pesquisar_pagina(text,text,integer,integer,integer,integer) to anon,authenticated;


