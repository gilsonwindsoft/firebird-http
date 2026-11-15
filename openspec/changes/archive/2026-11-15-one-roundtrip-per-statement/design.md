# Design

## Context

Ver `proposal.md` (Why). O que condiciona a solução:

- O driver Devart é síncrono: cada `isc_*` espera o retorno antes da próxima chamada. A sequência por comando é `start_multiple`, `alloc2`, `prepare`, `sql_info(21)`, `describe`, `sql_info(4 7 9 25 8)`, `execute2`, `sql_info(23)`, `fetch…`, `free(close)`, `free(drop)`, `commit` (`docs/api-surface.md`). O driver precisa do resultado do `describe` para montar o `XSQLDA` antes do `execute2`. Logo, sem conhecimento local, `PREPARE` e `EXECUTE` não podem ir na mesma requisição.
- A DLL já tem a infraestrutura de adiamento: `TFbAttachment.Pending` (operações `FLAG_DEFERRED` enviadas na próxima requisição) e `START_TRANSACTION` com id escolhido pelo cliente (`CLIENT_TR_BASE`), inserido por `TFbAttachment.Send` antes das operações. O gateway processa o lote em ordem e para no primeiro erro de operação não adiada (`server.run`).
- O gateway já constrói o `XSQLDA` de saída do `EXECUTE` a partir do `layout` que o cliente manda; a descrição real só é usada para responder ao `PREPARE`.
- `MaxFetchRows` do gateway já é 5 000; a DLL pede 1 000 por padrão (`fetch_rows`). O gzip da resposta já existe.
- O único número medido é em rede local. Não existe `docs/performance.md`.

## Goals / Non-Goals

**Goals:**

- 1 requisição por `SELECT` repetido com commit; 2 por escrita repetida com commit; 0 por transação vazia.
- Comportamento idêntico ao cliente nativo no roteiro `fbcompare` com as otimizações ligadas.
- Cada otimização desligável por configuração, e a DLL nova funcionando com gateway antigo.
- Números medidos antes e depois, com latência simulada e em nuvem, por etapa, em requisições e em ms.

**Non-Goals:**

- Trocar o transporte HTTP. Não reduz idas e voltas (driver síncrono) e custaria reescrever DLL, gateway, nginx e deploy.
- Leitura antecipada de lotes em thread própria (`FETCH` enquanto o driver consome). Ganho só em consultas acima do lote; fica para depois da medição.
- Cache de preparação compartilhado entre conexões ou persistido em disco.
- Compressão da requisição (corpos de requisição são pequenos; só `PUT_SEGMENTS` é grande e BLOB raramente comprime).

## Decisions

### D1. Não reescrever: atacar o número de idas e voltas na DLL

Alternativas consideradas:

| Abordagem | Idas e voltas por `SELECT` repetido | Observação |
|---|---|---|
| Hoje (HTTP, 3 requisições) | 3 | medido só em rede local |
| WebSocket / HTTP/2 / TCP próprio | 3 | mesma sequência síncrona do driver; só muda overhead por requisição, que é pequeno frente a 30–80 ms |
| Protocolo nativo do Firebird por VPN | ~4 | é o ponto de partida do usuário |
| Driver dbExpress próprio | 1 possível | API do dbExpress sem documentação, presa à versão do Delphi; descartado no projeto original |
| **DLL com cache de preparação + commit adiado (esta mudança)** | **1** | muda só a DLL, o protocolo (compatível) e o gateway |

A conta que justifica: com 60 ms de ida e volta, 20 datasets por tela = 3,6 s hoje contra 1,2 s depois. Nenhum transporte recupera isso.

### D2. Cache de preparação por conexão, chave exata

- Local: `TFbAttachment`, um dicionário `RawByteString` (dialeto + bytes do SQL, sem normalizar) → `TFbPrepEntry` (`StmtType`, `OutDesc`, `InDesc`, `PrepInfo`). Chave exata porque o ERP repete o SQL byte a byte; normalizar espaços traria risco sem ganho.
- Tamanho: `prepare_cache` entradas (padrão 256; 0 desliga), descarte LRU simples (lista de uso). Cada entrada tem só descrições, centenas de bytes.
- Por conexão e não global: evita lock global e evita misturar bancos ou usuários diferentes no mesmo processo (a aplicação abre 8 conexões).

### D3. `PREPARE` adiado com id de comando do cliente, na mesma fila de pendentes

- Em `W_isc_dsql_prepare` com acerto no cache: o statement recebe `ServerId := CLIENT_STMT_BASE or contador` (mesma faixa `≥ 0x80000000` das transações, contador global atômico), `Prepared := True`, descrições copiadas do cache, e a operação `PREPARE` entra em `Pending` **sem** `FLAG_DEFERRED` (o erro dela deve parar o lote e chegar à aplicação). Se o statement já tinha `ServerId` de gateway (re-prepare do mesmo handle), usa esse id e não precisa de id do cliente.
- Transação ainda não iniciada: o `START` precisa ir antes do `PREPARE`. `Send` hoje insere o `START` entre `Pending` e `Ops`; passa a inserir o `START` na fila na hora em que o `PREPARE` é enfileirado (`t.StartQueued := True`), e `Send` só acrescenta `START` para transações sem `Started` e sem `StartQueued`. Se o `START` falha, a fila é descartada, `t.Started` continua falso, e o próximo uso envia o `START` de novo (um `START` que falhou não registra o id no gateway).
- `W_isc_dsql_sql_info` já responde localmente `stmt_type` e os itens de prepare a partir de `s.StmtType` e `s.PrepInfo`; nada muda ali.
- `EXECUTE` que vai no mesmo lote do `PREPARE` adiado leva a descrição esperada (tipos de saída e de entrada do cache). O gateway compara `sqltype`, `sqlscale`, `sqlsubtype` e `sqllen` de cada variável com a descrição real; diferença → erro de protocolo `fbhttp: statement description changed` (categoria 3, sem invalidar a sessão). A DLL, ao ver esse erro, remove a entrada do cache e devolve ao driver um status vector `isc_dsql_sqlda_err` com essa mensagem, que é o erro que o cliente nativo dá quando o `XSQLDA` não bate.
- Erro do Firebird no `PREPARE` adiado (tabela removida): o lote para, `Send` levanta `EFbRemote` com o status vector real; a aplicação vê o erro no `execute` em vez de no `prepare`. A DLL remove a entrada do cache e marca o statement como não preparado.
- `free(drop)` de um statement com `PREPARE` ainda pendente e nunca executado: as duas operações saem da fila sem ir à rede (`shortcut: só quando o PREPARE é a última operação da fila; caso raro, revisar se aparecer no log de diagnóstico`).

Alternativa rejeitada: cache de prepare no gateway (por sessão, por SQL). Não ajuda: o driver precisa da descrição na estação antes do `EXECUTE`; o custo é a ida e volta, não o prepare do Firebird.

### D4. Validação da descrição no gateway, não "confiar e torcer"

O gateway já monta o `XSQLDA` pelo layout do cliente, então uma descrição obsoleta executaria com coerção silenciosa (tipos compatíveis) ou com erro genérico do Firebird (contagem diferente). Comparar explicitamente dá um erro claro e permite à DLL invalidar a entrada certa. Custo: alguns bytes a mais no `EXECUTE` só quando o `PREPARE` foi adiado.

### D5. Encerramento adiado só para transação sem escrita, com descarga por tempo

- `TFbTransaction.Wrote` vira `True` em: `DoExecute` com `StmtType` fora de `{1 SELECT}` (inclui `12 SELECT FOR UPDATE`, `8 EXEC PROCEDURE`, DML, DDL, `SET GENERATOR`), `exec_immed2`, `create_blob2`. Um `SELECT` de procedure selecionável que grava não é detectado; é o risco documentado (R2).
- `EndTransaction`: se `defer_readonly_commit=1` e `not t.Wrote` → se `t.Started` ou `t.StartQueued`, enfileira a operação com `FLAG_DEFERRED` (o erro não deve parar o lote; vai ao log de diagnóstico) e retorna 0; se nunca iniciou, não enfileira nada. Com `t.Wrote`, caminho atual (síncrono); `Send` já manda `Pending` antes, então os encerramentos adiados saem antes do `COMMIT` de escrita, na ordem.
- Descarga por tempo: a thread `TKeepAlive` passa a acordar a cada 250 ms. Para cada conexão com `Pending` não vazio e ociosa há `deferred_flush_ms` (padrão 1 000), faz `Lock.TryEnter`; se conseguir, chama `Send([])` (só pendentes). `TryEnter` evita bloquear a thread da aplicação; se a aplicação está usando a conexão, ela mesma descarrega na próxima chamada. O ping continua como hoje.
- `isc_detach_database` já passa por `Send`, que descarrega pendentes antes do `DETACH`.

Alternativa rejeitada: adiar também o `COMMIT` de escrita com descarga rápida. O retorno de `Commit` deixaria de significar "gravado"; num ERP isso é inaceitável, e o ganho (2 → 1 requisição por escrita) não compensa.

### D6. Lote maior, limitado por bytes no gateway

- `fetch_rows` padrão na DLL: 5 000 (= `MaxFetchRows`). `FBHTTP_MAX_BATCH_BYTES` no gateway, padrão 4 MB (antes do gzip).
- `srv.fetch` passa a buscar do `libfbclient` em blocos de 256 linhas e a parar quando os bytes codificados passam do limite, garantindo pelo menos uma linha. Sem mudança de codificação do `batch`: a DLL já trata "menos linhas que o pedido sem `eof`" pedindo o próximo lote.
- Memória na estação: no máximo um lote por cursor aberto (≤ 4 MB + inflado do gzip). `FOR UPDATE` continua com 1 linha por lote.

### D7. Versão 2 do protocolo, sem compatibilidade com a 1

- Não há nada em produção, então a versão 1 é substituída, não mantida. `protocol.Version = 2` nos dois lados; o gateway recusa qualquer outra com o erro de versão já existente. `PREPARE` aceita `stmt ≥ 0x80000000`; `EXECUTE` ganha, após `u32 fetch`, `u8 has_expected` + `layout out` + `layout in` (campo sempre presente, `0` quando não há descrição esperada); `FETCH`/`EXECUTE` aplicam o limite de bytes.
- Sem modo de recuo na DLL: menos um caminho de código e de teste. DLL e gateway sobem juntos.
- Alternativa rejeitada: aceitar `{1, 2}` com recuo automático na DLL. Só valeria com estações em produção que não podem ser atualizadas junto do gateway.

### D8. Medição

- Gateway: `exec` acumula o tempo de cada operação; a linha de log `request` ganha `fb_ms` (tempo dentro das operações, que é quase todo `libfbclient`). `ms − fb_ms` é o custo de HTTP, gzip e fila da sessão.
- DLL: `TFbTransport.Post` mede e acumula `Requests`, `NetMs`, `BytesOut`, `BytesIn`; `DebugLog` por requisição com opcodes, tamanhos e ms (sem SQL). Export novo `ws_fbclient_stats(out: PWsFbStats): Integer; stdcall` (função `W_ws_fbclient_stats`, exportada pelo `gen_wsfbclient.py` como as demais) devolve os totais do processo. O `fbcompare` chama por `GetProcAddress(GetModuleHandle('fbclient.dll'))` quando o export existe e grava, por etapa, `requests` e `net ms` ao lado do tempo; com o cliente nativo as colunas ficam vazias.
- `docs/performance.md`: tabela por etapa (tempo, requisições, ms de rede) em três cenários: local, 30 ms simulado (clumsy ou `tc netem`), gateway em nuvem; para "antes" (`prepare_cache=0`, `defer_readonly_commit=0`, `fetch_rows=1000`) e "depois" (padrões novos). Mais os totais das telas principais da aplicação real pelo `FBHTTP_DEBUG_LOG`.

### D9. Implantação do gateway junto do Firebird

`docs/deploy.md` passa a dizer: gateway no mesmo host do Firebird (ou `FBHTTP_FIREBIRD_HOST` em rede < 1 ms), e como confirmar pelo `fb_ms` do log. Um `PREPARE`+`EXECUTE`+lote faz 5–10 chamadas ao `libfbclient`; a 2 ms cada, em outra zona, isso é 20 ms por requisição que nenhuma otimização da DLL recupera.

## Risks / Trade-offs

- [R1 Descrição obsoleta após DDL] → gateway valida e devolve erro específico; a DLL invalida a entrada; o próximo prepare vai à rede. A aplicação vê um erro uma vez naquele comando. `prepare_cache=0` desliga.
- [R2 Commit adiado de transação que gravou via procedure selecionável, ou leitura em outra conexão logo após o commit] → a confirmação sai na próxima requisição da conexão ou em ≤ `deferred_flush_ms`; uma queda do processo nessa janela perde a gravação dessa procedure. `defer_readonly_commit=0` desliga. Documentado em `client-setup.md`.
- [R3 Erro de operação pendente aparece numa chamada posterior] → só `PREPARE` adiado (não `FLAG_DEFERRED`) pode interromper; o erro chega no `execute` do mesmo statement, com o status vector real. Encerramentos adiados são `FLAG_DEFERRED` e só vão ao log.
- [R4 `START` enfileirado falha] → fila descartada, `t.Started = False`, `t.StartQueued = False`; próximo uso reenvia. Gateway não registra id de `START` que falhou (já é assim).
- [R5 Memória com lote de 5 000 linhas] → limite de 4 MB por lote no gateway; a DLL libera linhas à medida que entrega (`s.Rows[i] := nil`, já existe).
- [R6 Thread de descarga concorrendo com a aplicação] → `TryEnter`; nunca espera. Uma descarga em andamento segura o lock por uma requisição; a aplicação espera como esperaria por qualquer chamada.
- [R7 Ganho menor que o previsto] → a medição (tarefas 1.x) vem antes do resto e é repetida ao fim; se `fb_ms` dominar, o problema é a distância gateway–Firebird (D9), não a DLL.

## Migration Plan

1. Gateway e DLL sobem juntos (protocolo 2; a DLL antiga recebe erro de versão).
2. Padrões novos ligados. Recuo: `prepare_cache=0`, `defer_readonly_commit=0`, `fetch_rows=1000` no `.ini` reproduzem o comportamento atual sem trocar a DLL; trocar a DLL pela anterior também funciona com o gateway novo.
3. `docs/performance.md` com antes e depois fecha a mudança. O "antes" é medido com a DLL atual (commit `08a2d59`) contra o gateway atual, antes do grupo 2, porque o gateway novo não aceita a DLL antiga.
