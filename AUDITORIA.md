# Auditoria da identidade dos atos

A coleta de atos, o cron diário, a extração geral de texto e o OCR de pesquisa permanecem suspensos. A auditoria usa uma fila independente e lê PDFs já associados aos registros; não descobre nem importa novos atos, não altera o cursor da coleta e não corrige cadastros automaticamente.

A execução cobre os atos em escopo e todos os PDFs associados. Atos sem PDF são inconclusivos. Compilações e anexos são separados para revisão do original. O comparador usa somente a primeira identificação de Portaria ou Resolução nas primeiras linhas, aceita número/ano e datas por extenso e distingue GP/GPRE, VP e DG. Não extrai o número do processo SEI nem usa referências do corpo como identificação do ato. Ausência de evidência suficiente resulta em inconclusivo, nunca em aprovação presumida.

Resultados: `conferente_automatico`, `divergente`, `inconclusivo`. Compatibilidade automática não equivale a revisão humana. Cada item conserva cadastro original, URL, categoria, identificação candidata, trecho, método, hash da evidência e data. No download, o hash corresponde ao PDF; na leitura de texto já extraído, corresponde ao trecho analisado. O método distingue essas situações.

A primeira versão do parser foi substituída após teste com citações de atos anteriores; sua execução permanece preservada como `substituida_por_parser_revisado` e não deve ser usada como relatório atual. A execução ativa é a versão 2, com testes de data por extenso, SEI, atos referenciados, tipo e emissor.

O workflow `.github/workflows/audit-pdfs.yml` executa lotes independentes na nuvem a cada 20 minutos, até 500 PDFs e aproximadamente 10 minutos de trabalho por lote. PDF inacessível ou ilegível é registrado para revisão. A função `trt16-audit` valida assinatura OIDC, emissor, audiência, IDs imutáveis do repositório e proprietário, branch main e caminho do workflow. Acesso aos RPCs e tabelas de auditoria é exclusivo do servidor. Nenhuma chave administrativa é enviada ao GitHub.

## Recuperação de falhas de comunicação

O worker faz no máximo três tentativas para obter autenticação e para gravar resultados após falhas transitórias de rede ou HTTP 408, 429, 500, 502, 503 e 504. Após HTTP 401, obtém uma nova credencial OIDC antes de repetir a operação. Falhas permanentes, como HTTP 400, não são repetidas. As esperas são limitadas a 1 e 2 segundos.

A reserva (`claim`) não é repetida após uma resposta ambígua ou perda de conexão, pois o servidor pode já ter reservado um item. A fila existente permite retomar reservas vencidas, respeitando o limite de tentativas do servidor. Uma resposta de gravação sem confirmação (`saved: false`) continua sendo tratada como pendência, inclusive quando uma resposta anterior possa ter sido perdida; não se presume sucesso.

Uma falha individual não descarta os resultados dos outros itens já reservados no lote. Após processá-los, o worker interrompe novas reservas e termina com erro se houver falhas técnicas pendentes. Isso evita consumir a fila durante indisponibilidade e mantém o alerta do GitHub Actions.

O resumo do job e o artefato `audit-report-<run_id>-<attempt>` registram contagens confirmadas, IDs sem confirmação e tipo/status HTTP das falhas. O workflow tenta preservar o relatório mesmo se o worker falhar; a retenção é de 30 dias. Tokens, leases e corpos de resposta não integram o relatório. Resultados inconclusivos por falta de evidência permanecem separados das falhas técnicas de gravação. Os testes podem ser executados com `python3 -m unittest -v test_audit_worker.py`.

## Correções verificadas

A tabela privada `trt16_correcoes_verificadas` reserva valores confirmados por revisão humana, com PDF, evidência, revisor e data. O trigger `trt16_identidade_protegida` aplica os valores protegidos em INSERT/UPDATE e grava tentativas divergentes em `trt16_conflitos_correcao`. O teste de proteção foi executado em transação revertida. Não existem correções verificadas aplicadas automaticamente pela auditoria.

Antes de confirmar uma correção, verificar cabeçalho visualmente, existência de outro ato com a mesma identidade e todos os originais do registro. Em caso de conflito de unicidade, não fundir ou apagar dados: resolver a associação na revisão. Depois, registrar a correção e atualizar o cadastro em uma transação. Não remover a evidência anterior. O trigger preserva a identidade corrigida nas próximas atualizações da mesma fonte.

## Consulta de progresso

```sql
select i.estado,count(*) from public.trt16_auditoria_itens i
join public.trt16_auditorias a on a.id=i.auditoria_id
where a.estado='em_andamento' group by i.estado;
```

Relatório local parcial de 09/10/2026: 700 PDFs com texto disponível, 630 compatíveis automaticamente, 2 divergentes e 68 inconclusivos. O universo tem 20.546 atos e 21.561 PDFs, além de 2 atos sem PDF. Essas contagens parciais não constituem percentual de confiabilidade da base completa.

