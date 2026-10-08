create or replace function public.trt16_pesquisar_pagina(q text default '',tipo_filtro text default '',ano_filtro integer default null,numero_filtro integer default null,pagina_num integer default 1,tamanho_pagina integer default 25)
returns jsonb language sql stable security invoker set search_path = '' as $$
 with termos as (
 select to_tsquery('simple', string_agg(quote_literal(token)||':*',' & ')) as consulta
 from regexp_split_to_table(regexp_replace(left(q,300),'[^[:alnum:]_]+',' ','g'),'\s+') as token where token<>''
 ), filtrados as (
 select a.* from public.trt16_atos a cross join termos t
 where a.em_escopo and (t.consulta is null or to_tsvector('simple',a.campo_busca) @@ t.consulta)
 and (tipo_filtro='' or a.tipo=tipo_filtro)
 and (ano_filtro is null or a.ano=ano_filtro)
 and (numero_filtro is null or a.numero=numero_filtro)
 ), contagem as (select count(*) as n from filtrados), limites as (
 select case when tamanho_pagina in (25,50,75,100) then tamanho_pagina else 25 end as tamanho
 ), paginacao as (
 select tamanho,greatest(1,least(greatest(1,coalesce(pagina_num,1)),greatest(1,ceil(n::numeric/tamanho)::int))) as atual,greatest(1,ceil(n::numeric/tamanho)::int) as paginas from limites cross join contagem
 ), pagina as (select * from filtrados order by ano desc,numero desc limit (select tamanho from paginacao) offset (select (atual-1)*tamanho from paginacao))
 select jsonb_build_object(
 'resultados',coalesce((select jsonb_agg((to_jsonb(p)-'campo_busca') || jsonb_build_object('arquivos',coalesce((select jsonb_agg(to_jsonb(f) order by f.ordem,f.id) from public.trt16_arquivos f where f.ato_id=p.id),'[]'::jsonb)) order by ano desc,numero desc) from pagina p),'[]'::jsonb),
 'encontrados',(select count(*) from filtrados),
 'pagina',(select atual from paginacao),'paginas',(select paginas from paginacao),'tamanho_pagina',(select tamanho from paginacao),
 'total',(select count(*) from public.trt16_atos where em_escopo),
 'base',(select to_jsonb(b)-'id' from public.trt16_base b where id=1),
 'anos',coalesce((select jsonb_agg(ano order by ano desc) from (select distinct ano from public.trt16_atos where em_escopo) y),'[]'::jsonb))
$$;
revoke all on function public.trt16_pesquisar_pagina(text,text,integer,integer,integer,integer) from public;
grant execute on function public.trt16_pesquisar_pagina(text,text,integer,integer,integer,integer) to anon,authenticated;
