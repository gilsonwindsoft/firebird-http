# Protocolo fbhttp v1

Contrato binário entre `ws-fbclient.dll` (cliente) e `fbhttp-gateway` (servidor).
Requisitos: `openspec/changes/add-dbexpress-http-driver/specs/gateway-protocol/spec.md`.

## Transporte

| Endpoint | Uso |
|---|---|
| `POST /v1/rpc` | Executa um lote de operações. Header `X-Session: <token>` em toda requisição, exceto na que contém `ATTACH`. |
| `POST /v1/ping` | Keep-alive. Header `X-Session`. Sem corpo, sem `seq`, não espera a sessão ficar livre. Responde `204`, ou `410` se a sessão não existe. |

`Content-Type: application/x-fbhttp`. Códigos HTTP: `200` para toda requisição decodificável (erros de operação, sessão inválida, versão e limites vão no corpo), `400` corpo malformado, `413` corpo maior que `max_body_bytes`. `GET /healthz` responde `204` (healthcheck).

## Tipos primitivos

Tudo little-endian.

| Nome | Codificação |
|---|---|
| `u8 u16 u32 i16 i32 i64` | inteiro de tamanho fixo |
| `bytes` | `u32` tamanho + bytes |
| `str` | igual a `bytes` (texto sem conversão de charset) |
| `quad` | 8 bytes crus (`ISC_QUAD`) |

## Requisição

```
u32 version        = 1
u32 seq            1 no ATTACH; depois +1 a cada requisição
u16 count
count × op:
  u16 opcode
  u8  flags        bit0 = adiada: erro desta operação é ignorado e não interrompe o lote
  bytes payload
```

## Resposta

```
u16 count          número de operações processadas (para no primeiro erro de operação não adiada)
count × result:
  u16 opcode
  u8  status       0 = ok, 1 = erro
  bytes payload    resultado da operação, ou bloco de erro
```

## Bloco de erro

```
u8  category       1 Firebird, 2 sessão, 3 protocolo, 4 limite, 5 interno
i32 sqlcode        isc_sqlcode() do status vector (0 se não for Firebird)
status vector:     repetir até tag 0
  u32 tag
  tag 0                 fim
  tag 2,5,19 (string)   str
  tag 3 (cstring)       str
  demais tags           i64 valor
u16 n_messages
n × str            linhas produzidas por fb_interpret, em ordem
```

Erro de categoria 2 (sessão) invalida a sessão. As demais não.

## Descritor de variável (XSQLVAR)

```
i16 sqltype        inclui o bit 1 de nullable
i16 sqlscale
i16 sqlsubtype
i16 sqllen
str sqlname, str relname, str ownname, str aliasname
```

`desc` = `u16 n` + `n × var`. `layout` = `u16 n` + `n × (i16 sqltype, i16 sqlscale, i16 sqlsubtype, i16 sqllen)`.
Um layout com `n = 0xFFFF` significa "sem XSQLDA".

## Linha

Para cada variável do layout:

```
u8 isnull          1 = NULL, sem dados a seguir
dados              SQL_VARYING (448): u16 tamanho + bytes
                   demais tipos: exatamente sqllen bytes, no formato nativo do Firebird
```

`batch` = `u32 nrows` + `nrows × linha` + `u8 eof`.

## Operações

Handles (`db`, `tr`, `stmt`, `blob`) são IDs `u32` opacos da sessão. Zero é inválido.

| Op | Nome | Entrada | Saída |
|---|---|---|---|
| 1 | ATTACH | `str dbname`, `bytes dpb` | `str token`, `u32 db` |
| 2 | DETACH | `u32 db` | — |
| 3 | DATABASE_INFO | `u32 db`, `bytes items`, `u32 buflen` | `bytes result` |
| 10 | START_TRANSACTION | `u32 db`, `bytes tpb`, `u32 want` (0 = o gateway escolhe; ≥ 0x80000000 = id escolhido pelo cliente) | `u32 tr` |
| 11 | COMMIT | `u32 tr` | — |
| 12 | ROLLBACK | `u32 tr` | — |
| 13 | COMMIT_RETAINING | `u32 tr` | — |
| 14 | ROLLBACK_RETAINING | `u32 tr` | — |
| 15 | TRANSACTION_INFO | `u32 tr`, `bytes items`, `u32 buflen` | `bytes result` |
| 20 | PREPARE | `u32 db`, `u32 tr`, `u32 stmt` (0 = alocar), `u16 dialect`, `str sql`, `bytes info_items`, `u32 info_buflen` | `u32 stmt`, `i32 stmt_type`, `desc out`, `desc in`, `bytes info` |
| 21 | FREE | `u32 stmt`, `u16 option` (1 close, 2 drop, 4 unprepare) | — |
| 22 | EXECUTE | `u32 tr`, `u32 stmt`, `u16 dialect`, `layout in` + `linha` (se n≠0xFFFF), `layout out`, `u32 fetch` | `u8 kind` + dados (abaixo) |
| 23 | EXECUTE_IMMEDIATE | `u32 db`, `u32 tr`, `u16 dialect`, `str sql`, `layout in` + `linha`, `layout out` | `u32 tr` (pode mudar), `u8 hasrow` + `linha` |
| 24 | FETCH | `u32 stmt`, `layout out` (0xFFFF = manter o atual), `u32 count` | `batch` |
| 25 | SET_CURSOR_NAME | `u32 stmt`, `str name` | — |
| 26 | SQL_INFO | `u32 stmt`, `bytes items`, `u32 buflen` | `bytes result` |
| 30 | OPEN_BLOB | `u32 db`, `u32 tr`, `quad id`, `bytes bpb`, `u32 inline_limit` | `u32 blob`, `bytes info`, `u8 complete`, `bytes data` |
| 31 | GET_SEGMENTS | `u32 blob`, `u32 maxbytes` | `bytes data`, `u8 eof` |
| 32 | CREATE_BLOB | `u32 db`, `u32 tr`, `bytes bpb` | `u32 blob`, `quad id` |
| 33 | PUT_SEGMENTS | `u32 blob`, `u32 n`, `n × bytes` | — |
| 34 | CLOSE_BLOB | `u32 blob` | — |
| 35 | CANCEL_BLOB | `u32 blob` | — |
| 36 | BLOB_INFO | `u32 blob`, `bytes items`, `u32 buflen` | `bytes result` |

### START_TRANSACTION com id do cliente

Com `want ≥ 0x80000000`, o gateway registra a transação com esse id. Assim o cliente pode adiar o START e enviá-lo no mesmo lote da operação que usa a transação (ex.: START + PREPARE). Um id fora dessa faixa ou já em uso é erro de protocolo.

### PREPARE com itens de informação

`info_items` (pode ser vazio) é passado a `isc_dsql_sql_info` depois do prepare e o resultado volta em `info`. O cliente guarda o resultado e responde localmente as chamadas `isc_dsql_sql_info` com a mesma lista de itens (ver `docs/api-surface.md`).

### EXECUTE

O gateway monta o XSQLDA de saída com o `layout out` que o cliente enviou, porque o cliente pode ter mudado tipos depois do describe (coerção).

Modo de execução:

- comando com cursor (stmt_type 1 ou 12) e `fetch > 0`, ou sem `layout out`: abre o cursor (`isc_dsql_execute`) e devolve até `fetch` linhas;
- comando com cursor, `fetch = 0` e `layout out`: `isc_dsql_execute2` (SELECT singleton);
- demais comandos: `isc_dsql_execute2` com o `layout out` (ou sem saída).

Erros e comportamento são os do `libfbclient`. Exemplo: SELECT singleton sem linhas devolve `isc_stream_eof`.

`kind` da resposta:

- `0` — sem dados. Segue `bytes records`: resultado de `isc_dsql_sql_info(isc_info_sql_records)`, para o cliente responder "linhas afetadas" sem nova requisição.
- `1` — `execute2` com saída (ex.: `EXECUTE PROCEDURE`). Segue `u8 hasrow` + `linha` e `bytes records`.
- `2` — cursor aberto. Segue `bytes records` (lido logo após abrir, antes de buscar linhas, como o cliente nativo vê) e `batch` com até `fetch` linhas. `SELECT ... FOR UPDATE` (stmt_type 12) sempre usa no máximo 1 linha por lote, para `WHERE CURRENT OF` continuar correto.

### OPEN_BLOB

`info` = resultado de `isc_blob_info` com os itens `isc_info_blob_total_length`, `isc_info_blob_max_segment`, `isc_info_blob_num_segments`, `isc_info_blob_type`.
Se o tamanho total ≤ `inline_limit`, `complete = 1`, `data` traz o conteúdo inteiro e o gateway já fechou o BLOB (o handle devolvido é 0).

## Sequência e repetição

Cada sessão guarda o último `seq` processado e a resposta dele.

| `seq` recebido | Ação |
|---|---|
| último + 1 | executa |
| igual ao último, já terminado | devolve a resposta guardada |
| igual ao último, ainda executando | espera terminar e devolve a mesma resposta |
| outro valor | erro de protocolo (categoria 3) |

`ATTACH` sempre usa `seq = 1` e não tem sessão. Uma repetição de `ATTACH` cria outra sessão; a sessão anterior expira por inatividade.
