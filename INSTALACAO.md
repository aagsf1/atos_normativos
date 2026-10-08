# Pesquisa de atos administrativos do TRT16

Página estática destinada ao GitHub Pages, com busca em PostgreSQL/Supabase.

## Cobertura

Amostra de dez atos; não é uma cópia integral da biblioteca. Resumos adaptados, com links para fontes e dois PDFs oficiais. Não há cópias de PDFs no Google Drive nem pesquisa no texto integral dos documentos.

## Configuração

1. Executar `schema.sql` no projeto Supabase escolhido e depois `seed.sql`.
2. Informar em `config.js` a URL do projeto e uma chave **publicável** habilitada. Não usar chaves secretas ou `service_role`.
3. Habilitar GitHub Pages nas configurações do repositório: Deploy from a branch, `main`, pasta `/ (root)`.

A tabela `trt16_atos` tem RLS e concede somente SELECT a visitantes e usuários autenticados. A função de pesquisa usa SECURITY INVOKER. Importação deve ocorrer por um canal administrativo separado; a página não oferece edição.

## Verificações necessárias antes da entrega

Consulta real pela chave publicável, filtro combinado, pesquisa sem acentos, resultado vazio, tentativa de escrita pública recusada e abertura da URL do GitHub Pages. A configuração vazia mostra aviso de instalação pendente.

## Desenvolvimento local

Servir esta pasta com `python -m http.server 8766` e abrir http://127.0.0.1:8766. A versão original com SQLite continua na pasta irmã `trt16` e não foi alterada.

Os arquivos SQL são scripts de instalação revisáveis, sem credenciais; não são arquivos gerados pelo Supabase CLI.

## Vários PDFs por ato

A tabela `trt16_arquivos` vincula múltiplos PDFs a um ato, preservando URL direta por bitstream, nome, categoria, descrição, data da versão quando confirmada, ordem e data de coleta. A pesquisa devolve todos os arquivos. Não se presume que a última compilação esteja vigente. A categoria só deve ser atribuída com evidência nos metadados ou no documento; os dois PDFs da amostra ficam como não classificados.

Exemplo verificado na biblioteca: Portaria 106/2026, registro https://bibliotecadigital.trt16.jus.br/entities/publication/624c9d7d-605a-44b5-9c54-68a9b33bb32c/full, possui Texto Principal.pdf e Texto Consolidado.pdf. O segundo informa compilação da alteração pela Portaria 188/2026. Esse ato não foi adicionado à amostra porque seus dois endereços diretos ainda não foram coletados.


## Coleta automática instalada

O projeto atos_normativos executa a função trt16-sync com JWT obrigatório e token privado do Vault. O agendador inicia ciclos às 06:00 UTC (03:00 em Brasília) e processa lotes de 25 atos a cada minuto. A primeira carga está em andamento: Portarias e Resoluções de 2026, seguidas dos anos anteriores até 1989. Se um ciclo ainda estiver em andamento no horário diário, continua do ponto salvo. Após cinco falhas consecutivas, interrompe o ciclo e tenta novamente no próximo horário diário.

A fonte é a API DSpace oficial. Ementas e autoria são copiadas do catálogo; todos os PDFs do pacote ORIGINAL são relacionados usando /server/api/core/bitstreams/{UUID}/content. O campo pdf_url mantém o principal, enquanto trt16_arquivos conserva os arquivos relacionados. Não são feitas cópias dos PDFs.

Base de Pesquisa apresenta contagem atual e data da última gravação bem-sucedida, no horário de Brasília. A conclusão de um ciclo completo é registrada separadamente. Os registros anteriormente importados são preservados quando a fonte fica indisponível; a coleta não remove automaticamente atos que saíram do catálogo.

Os scripts sync.sql e sync.ts documentam a automação deste projeto. Para reinstalar em outro projeto, revisar a URL fixa em sync.sql, registrar a chave anon JWT em vault.trt16_sync_anon_jwt e configurar a função com verify_jwt=true. Nunca publicar o token privado ou a chave service_role.


## Pesquisa no conteúdo dos PDFs

Instalar `pdf-text.sql`, publicar `pdf-text.ts` como Edge Function `trt16-pdf` com verificação JWT e reaplicar `pagination.sql`. O worker usa o mesmo token privado no Vault da coleta e só pode gravar com `service_role`. A cada minuto extrai um PDF pendente, em ordem decrescente de ano e número. A fila permanece ativa durante e depois da coleta, incluindo novos arquivos automaticamente; erros são repetidos até cinco tentativas. URLs oficiais são preservadas. O texto é armazenado no banco, sem hospedar cópia dos PDFs.

A pesquisa combina metadados com o texto de cada PDF individualmente e aceita E/OU. A resposta pública não inclui textos completos nem campos internos da fila. A página informa quantos PDFs já foram indexados. Arquivos sem texto suficiente são marcados `ocr_pendente`: OCR ainda exige um worker próprio de processamento de imagens, não é executado pela Edge Function. Limite atual por arquivo: 15 MB. PDFs maiores e inacessíveis aparecem como erro de extração, sem interromper a importação de atos.
