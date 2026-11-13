# API do fbclient usada pelo driver Devart (resultado da tarefa 1.3)

Fonte: logs do proxy (`client/proxy`) com `WS_SisCom.exe`, driver Devart dbExpress para InterBase/Firebird (`dbexpida40.dll`), Delphi 10.3, Firebird 3+, 13/11/2026. Duas execuções: com e sem o export `fb_get_master_interface`. O resultado foi o mesmo.

## Decisões que o log fecha

| Pergunta | Resposta | Efeito |
|---|---|---|
| O driver usa a API OO do Firebird 3+? | **Não.** `fb_get_master_interface` nunca é chamada e a aplicação funciona sem esse export. | O design (API legada `isc_*`) se mantém. |
| O driver muda o XSQLDA entre o describe e o fetch? | **Não.** O layout do primeiro fetch é igual ao do describe em 767 de 767 cursores. | O execute já abre o cursor e devolve o primeiro lote com o layout do describe (D8). |
| Como os cursores são abertos? | Por `isc_dsql_execute2` com XSQLDA de saída `nil` (767 vezes). `isc_dsql_execute` aparece 123 vezes, sempre com parâmetros. | Os dois caminhos abrem cursor com primeiro lote. |
| O `VendorLib` do `dbxconnections.ini` é respeitado? | **Não.** Com `VendorLib=aaaaa.dll` o driver carrega `fbclient.dll` da pasta da aplicação. | A forma de apontar para `ws-fbclient.dll` na estação ainda precisa ser definida (tarefa 7.5). |
| As conexões ficam numa thread só? | **Não.** As conexões são abertas na thread principal e também usadas por outra thread. | A DLL serializa as chamadas por conexão (lock do transporte). |

## Funções chamadas (sessão de ~74 s, 8 conexões)

| Função | Chamadas | Onde a DLL atende |
|---|---|---|
| `isc_vax_integer` | 18 723 | local (cálculo puro) |
| `isc_dsql_sql_info` | 2 296 | local, com os dados do PREPARE e do EXECUTE (tabela abaixo) |
| `isc_dsql_fetch` | 2 049 | local, do lote; rede só quando o lote acaba |
| `isc_dsql_free_statement` | 1 538 | adiada (vai junto na próxima requisição) |
| `isc_dsql_describe` | 1 230 | local, da resposta do PREPARE |
| `isc_dsql_execute2` | 780 | rede (EXECUTE) |
| `isc_dsql_alloc_statement2` | 771 | local (alocação vai junto no PREPARE) |
| `isc_dsql_prepare` | 771 | rede (PREPARE) |
| `isc_start_multiple` | 249 | adiada: id escolhido pelo cliente, START vai junto na próxima requisição |
| `isc_commit_transaction` | 249 | rede |
| `isc_dsql_execute` | 123 | rede (EXECUTE) |
| `isc_commit_retaining` | 106 | rede |
| `isc_blob_info` | 49 | local, da resposta do OPEN_BLOB |
| `isc_close_blob` | 49 | local (BLOB já completo) ou rede |
| `isc_get_segment` | 45 | local (BLOB embutido) ou rede em blocos |
| `isc_open_blob2` | 37 | rede (OPEN_BLOB com conteúdo embutido) |
| `isc_database_info` | 24 | cache por conexão (itens estáticos) |
| `isc_create_blob2` | 12 | rede |
| `isc_put_segment` | 12 | local (buffer), enviado no close |
| `isc_attach_database` | 8 | rede (ATTACH) |
| `isc_detach_database` | 8 | rede |
| `isc_get_client_version` | 1 | local |

Não houve erro no teste. Por isso as funções de mensagem não apareceram. A DLL implementa todas mesmo assim: `fb_interpret`, `isc_interprete`, `isc_sqlcode`, `isc_sql_interprete`, `isc_print_status`, `fb_sqlstate`. Também implementa `isc_rollback_transaction` e `isc_rollback_retaining`. As demais funções exportadas devolvem o status "not supported by ws-fbclient".

## Itens de informação pedidos

| Função | Itens (decimal) | Significado | Momento |
|---|---|---|---|
| `isc_dsql_sql_info` | `21` | `stmt_type` | logo após o prepare |
| `isc_dsql_sql_info` | `4 7 9 25 8` (buffer 1024) | select, describe_vars, sqlda_seq, relation_alias, describe_end | logo após o describe |
| `isc_dsql_sql_info` | `23` (buffer 1024) | `records` (linhas afetadas) | logo após cada execute, inclusive de cursor |
| `isc_database_info` | `62` / `103` (buffer 1024) | dialeto / versão do Firebird | após conectar |
| `isc_blob_info` | `4 5 6 7` | nº de segmentos, maior segmento, tamanho total, tipo | após abrir o BLOB |
| `isc_transaction_info` | — | não chamada | — |

## Parâmetros de conexão e transação

- `Database`: `localhost:ws-servico-trunk`. O gateway resolve o alias pelo texto depois do primeiro `:`.
- DPB v1: `28` (user), `29` (password), `63`, `77`.
- TPB: `isc_tpb_version3, wait, lock_timeout=20, read_committed, rec_version` (mais `write`). Alguns usam `read`.
- BLOB: BPB vazio.

## Custo em idas e voltas por comando típico

Padrão do driver: `start_multiple`, `alloc2`, `prepare`, `sql_info`, `execute2`, `describe` ×2, `sql_info`, `fetch`…, `free(close)`, `free(drop)`, `commit`.

| Etapa | Requisições |
|---|---|
| START (adiado) + PREPARE | 1 |
| EXECUTE + primeiro lote + linhas afetadas | 1 |
| fetch, describe, sql_info, free | 0 (local ou adiado) |
| COMMIT (+ frees adiados) | 1 |
| **Total** | **3** (contra ~12+ chamadas nativas) |
