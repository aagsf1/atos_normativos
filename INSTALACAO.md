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
