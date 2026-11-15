# Tasks

## 1. Medição de base (antes de otimizar)

- [x] 1.1 Gateway: acumular em `exec` o tempo de cada operação e acrescentar `fb_ms` à linha de log `request` em `server.go`; verificar com `go test ./internal/server/...` (teste de integração que lê o log e confere `fb_ms <= ms`)
- [x] 1.2 DLL: em `fbhttp.Transport.pas`, medir cada `Post` e acumular `Requests`, `NetMs`, `BytesOut`, `BytesIn` por transporte e em totais globais; gravar uma linha de `DebugLog` por requisição com opcodes, tamanhos e ms, sem SQL nem dados; verificar com um teste DUnitX em `client/tests` que confere os contadores após duas chamadas a um servidor falso
- [x] 1.3 DLL: exportar `ws_fbclient_stats` (`W_ws_fbclient_stats` em `fbhttp.Client.pas`, regenerar o projeto com `python3 client/tools/gen_wsfbclient.py`) devolvendo os totais globais; verificar que `build.bat` gera a DLL e que `dumpbin /exports` (ou o teste DUnitX) lista o export
- [x] 1.4 `fbcompare.dpr`: em `Step` e no `connect`, ler `ws_fbclient_stats` por `GetProcAddress` quando existir e gravar `requests` e `net ms` por etapa no `*.timing.txt`; verificar rodando `compare.bat` em rede local e conferindo as colunas novas só no arquivo `http.txt.timing.txt`
- [ ] 1.5 Criar `docs/performance.md` com o roteiro de medição (local, 30 ms simulado, nuvem) e registrar os números de base de `compare.bat` nos três cenários com a DLL e o gateway deste grupo (ainda protocolo 1; o grupo 2 quebra a compatibilidade, então a base tem de sair antes dele), mais o total de requisições e ms de rede das telas principais da aplicação real lido do `FBHTTP_DEBUG_LOG`; verificar que a tabela tem os três cenários preenchidos

## 2. Protocolo v2 no gateway

- [x] 2.1 `protocol.go`/`server.go`: `Version = 2`; `ATTACH` com qualquer outra versão recebe o erro de versão existente dizendo que só a 2 é aceita; verificar com teste em `client_test.go` para `ATTACH` v1 (recusado) e v2 (aceito)
- [x] 2.2 `ops.go`/`session.go`: `PREPARE` com `stmt ≥ 0x80000000` aloca e registra com esse id (`addAs`); id na faixa já em uso é erro de protocolo; falha no prepare não registra o id; verificar com teste de integração que envia `START(id cliente)`, `PREPARE(id cliente)`, `EXECUTE` num só lote e lê linhas, e outro com id repetido recebendo categoria 3
- [x] 2.3 `ops.go`: `EXECUTE` lê o campo `has_expected` + layouts (sempre presente, `0` = sem descrição) e compara tipo, escala, subtipo e tamanho com a descrição real do statement; diferença responde erro de protocolo `fbhttp: statement description changed` sem executar e sem invalidar a sessão; verificar com teste de integração que altera uma coluna por DDL entre o prepare e o execute
- [x] 2.4 `config.go`, `docker-compose.yml`, `.env.example`: `FBHTTP_MAX_BATCH_BYTES` (padrão 4 MB) com validação `> 0`; `srv.fetch` busca em blocos de 256 linhas e para ao passar do limite, com pelo menos uma linha e sem `eof`; verificar com `config_test.go` e teste de integração com linhas de 10 KB e limite de 64 KB que confere lote parcial e continuação correta
- [x] 2.5 `docs/protocol.md`: seção "Versão 2" com id de comando do cliente, campo opcional do `EXECUTE`, erro de descrição e limite de bytes; verificar que cada campo novo citado nos testes de 2.2–2.4 está documentado

## 3. DLL: protocolo v2 e cache de preparação

- [x] 3.1 `fbhttp.Protocol.pas`: versão 2 no `ATTACH`, campo `has_expected` + layouts no `EXECUTE` (vazio por padrão); atualizar `TestProtocol.pas` e as fixtures em `tests/protocol-fixtures` geradas pelos testes Go; verificar que `go test ./internal/protocol/...` e os testes DUnitX leem os mesmos bytes
- [x] 3.2 `fbhttp.Config.pas` e `ws-fbclient.example.ini`: chaves `prepare_cache` (padrão 256), `defer_readonly_commit` (padrão 1), `deferred_flush_ms` (padrão 1000), `fetch_rows` padrão 5000, com variáveis de ambiente `FBHTTP_*` correspondentes; verificar com `TestConfig.pas` (padrões, override por ambiente, `0` desliga)
- [x] 3.3 `fbhttp.Client.pas`: cache LRU por `TFbAttachment` (chave dialeto + SQL, valor `StmtType`, `OutDesc`, `InDesc`, `PrepInfo`), preenchido após cada `PREPARE` real; verificar com teste DUnitX de inserção, acerto, descarte LRU e `prepare_cache=0`
- [x] 3.4 `fbhttp.Client.pas`: em `W_isc_dsql_prepare` com acerto no cache, responder do cache, atribuir id de comando do cliente (ou reutilizar `ServerId` existente), enfileirar `START` da transação se ainda não iniciada (`StartQueued`) e o `PREPARE` sem `FLAG_DEFERRED`; `Send` deixa de acrescentar `START` para transações com `StartQueued`; verificar com teste de integração (gateway em Docker) que o segundo `prepare`+`execute` do mesmo SQL faz uma única requisição (contador de 1.2)
- [x] 3.5 `fbhttp.Client.pas`: `EXECUTE` que segue um `PREPARE` adiado envia a descrição esperada; ao receber o erro de descrição, remover a entrada do cache, marcar `Prepared := False` e devolver `isc_dsql_sqlda_err` com a mensagem; erro do Firebird no `PREPARE` adiado remove a entrada e chega ao driver com o status vector real; verificar com teste de integração que faz DDL entre dois usos do mesmo SQL e confere erro uma vez e sucesso na preparação seguinte
- [x] 3.6 `fbhttp.Client.pas`: `free(drop)` de statement com `PREPARE` pendente e nunca executado retira as duas operações da fila; verificar com teste DUnitX que a fila fica vazia e o contador de requisições não muda

## 4. DLL: encerramento adiado e descarga por tempo

- [x] 4.1 `fbhttp.Client.pas`: `TFbTransaction.Wrote` marcado em `DoExecute` (tipo ≠ SELECT), `exec_immed2` e `create_blob2`; `EndTransaction` enfileira `COMMIT`/`ROLLBACK` (`FLAG_DEFERRED`) para transação sem escrita quando `defer_readonly_commit=1`, não enfileira nada para transação nunca iniciada, e continua síncrono com escrita; verificar com teste de integração que um `SELECT`+commit faz 1 requisição, um `UPDATE`+commit faz 2 e que a ordem `COMMIT`, `START`, `PREPARE`, `EXECUTE` aparece no log do gateway
- [x] 4.2 `fbhttp.Client.pas`: `TKeepAlive` acorda a cada 250 ms e descarrega `Pending` de conexões ociosas há `deferred_flush_ms` com `Lock.TryEnter`; verificar com teste de integração que, após `SELECT`+commit e espera de 2 s, o gateway registra o `COMMIT` sem nova chamada da aplicação (`isc_transaction_info` ou log do gateway)
- [x] 4.3 `docs/client-setup.md`: documentar as chaves novas, o que o cache e o commit adiado mudam (erro único após DDL; janela de descarga em transação só de leitura; procedure selecionável que grava) e como desligar cada um; verificar que cada chave do `.ini` de exemplo está explicada

## 5. Comparação e medição final

- [ ] 5.1 Rodar `compare.bat` em FB 3, 4 e 5 com os padrões novos e confirmar `SAME` nos três; registrar os `*.timing.txt`
- [ ] 5.2 Rodar `compare.bat` com `prepare_cache=0`, `defer_readonly_commit=0` e `fetch_rows=1000` e confirmar `SAME` e requisições iguais à base de 1.5
- [ ] 5.3 Repetir a medição de 1.5 (local, 30 ms simulado, nuvem) com os padrões novos e com a aplicação real; preencher o "depois" em `docs/performance.md` com tempo, requisições e ms de rede por etapa, e a comparação com a base; verificar que o `SELECT` repetido com commit mostra 1 requisição
- [x] 5.4 `docs/deploy.md`: exigir gateway no mesmo host (ou rede < 1 ms) do Firebird e explicar `fb_ms` versus `ms` no log para separar rede de banco; `README.md`: atualizar a frase das "3 requisições" para os números medidos; verificar que os exemplos de log citados existem na saída real do gateway
