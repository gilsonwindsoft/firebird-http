# Proposal

## Why

O gateway funciona, mas o ganho de desempenho em rede com latência alta ficou abaixo do esperado. A causa é contável: o que determina o tempo de um comando numa rede de 30–80 ms não é o tamanho dos dados nem o custo do HTTP, é o **número de idas e voltas por comando**. Hoje a `ws-fbclient.dll` gasta 3 idas e voltas num comando típico do driver Devart (`PREPARE`, `EXECUTE` com primeiro lote, `COMMIT`). O `fbclient.dll` nativo, falando o protocolo de rede do Firebird 3+, gasta cerca de 4 (ele já adia `allocate` e `free`, e já junta `prepare` com `sql_info`). Reduzir de 4 para 3 é um ganho de 25%, que é o que foi observado. O MySQL parece rápido na nuvem porque um `SELECT` custa **1 ida e volta** (sem prepare no servidor, autocommit, resultado inteiro numa resposta).

Não há medição do projeto com latência real: a tarefa 7.3 do projeto original previa `docs/performance.md` e ele não existe. O único `*.timing.txt` é de rede local, onde a DLL já é mais rápida que o cliente nativo (4,3 s contra 6,1 s no roteiro de comparação), o que confirma que o custo é latência, não CPU nem transferência.

Reescrever o transporte (WebSocket, HTTP/2, TCP próprio) não muda essa conta: o driver é síncrono e espera a resposta de cada `isc_*` antes da próxima chamada, então qualquer transporte paga as mesmas idas e voltas. A única forma de chegar a 1 ida e volta por comando é a DLL **responder localmente** o que hoje pede ao gateway, usando conhecimento que ela acumula: a descrição de comandos já preparados e o fato de uma transação ser só de leitura. É isso que esta mudança faz, sem reescrever o projeto.

## What Changes

- **Medição antes de tudo.** O teste de comparação passa a registrar, por etapa, o número de requisições HTTP e o tempo médio de cada uma, além do tempo total. O log de diagnóstico da DLL (`FBHTTP_DEBUG_LOG`) registra cada requisição com tamanho, operações e duração. A comparação é rodada com latência simulada e contra o gateway em nuvem, e os números ficam em `docs/performance.md`. Sem isso não dá para saber se a redução de idas e voltas se traduziu em tempo.
- **Cache de preparação por conexão.** A DLL guarda, por texto SQL e dialeto, o resultado do `PREPARE` (tipo do comando, descrição de colunas e parâmetros, itens de `sql_info`). Quando o driver prepara de novo o mesmo SQL, a DLL responde `describe` e `sql_info` do cache e **adia o `PREPARE` real para a mesma requisição do `EXECUTE`**. O gateway valida que a descrição real é igual à que o cliente usou; se não for (DDL no meio), devolve erro, a DLL descarta a entrada e o próximo prepare volta ao caminho lento. Para o SQL repetido de um ERP (o caso dominante) o comando cai de 2 para 1 ida e volta.
- **Comando preparado com id escolhido pelo cliente.** Para o `PREPARE` ir no mesmo lote do `EXECUTE`, o cliente precisa saber o id do comando antes da resposta. O protocolo passa a aceitar id de comando escolhido pelo cliente, com a mesma regra já usada para transações (`want ≥ 0x80000000`).
- **COMMIT e ROLLBACK adiados em transação sem escrita.** A DLL rastreia se uma transação executou algum comando que pode escrever (qualquer `stmt_type` que não seja `SELECT`, `EXECUTE IMMEDIATE`, criação de BLOB). Para uma transação que só leu, `isc_commit_transaction`, `isc_commit_retaining` e `isc_rollback_*` são respondidos na hora e a operação vai na próxima requisição, antes das demais, na mesma ordem. Uma transação criada e encerrada sem nenhum comando não gera requisição nenhuma. Operações adiadas são enviadas de qualquer forma após um curto tempo ocioso, no `detach`, e antes de qualquer `COMMIT` de escrita, para a transação Firebird não ficar aberta à toa. Transações com escrita continuam com `COMMIT` síncrono: o retorno de `commit` para a aplicação continua significando "gravado".
- **Lote de linhas maior e limitado por bytes.** O gateway passa a limitar o lote por número de linhas e por bytes; o padrão de `fetch_rows` sobe para que um resultado de tamanho comum (milhares de linhas curtas) venha na resposta do `EXECUTE`. Com gzip já existente, o custo por byte é baixo; o custo por ida e volta não.
- **Implantação.** O guia de deploy passa a exigir o gateway no mesmo host (ou mesma rede de baixa latência) do Firebird, e a mostrar como ler no log do gateway o tempo gasto no Firebird por requisição, para separar latência de rede de tempo do banco.

Resultado esperado por comando típico, em idas e voltas (a validar em 2.1 e 6.x das tasks):

| Caso | Hoje | Depois |
|---|---|---|
| `SELECT` repetido com commit (TSQLQuery, TClientDataSet) | 3 | 1 |
| `SELECT` novo (primeira vez do SQL) | 3 | 2 |
| `INSERT/UPDATE/DELETE` repetido com commit | 3 | 2 |
| Abrir e fechar transação sem comando | 0 | 0 |

Com 60 ms de latência, uma tela que abre 20 datasets cai de 3,6 s para 1,2 s só de rede.

Fora do escopo (ficam como mudanças separadas se a medição mostrar necessidade): leitura antecipada de lotes (`FETCH` em paralelo ao consumo), cache compartilhado entre conexões, compressão da requisição, troca do transporte HTTP.

## Capabilities

### New Capabilities
- Nenhuma.

### Modified Capabilities
- `fbclient-http-library`: novo requisito de cache de preparação com resposta local a `describe`/`sql_info` e `PREPARE` adiado; novo requisito de `COMMIT`/`ROLLBACK` adiados em transação sem escrita; o requisito "Mesmo comportamento do cliente nativo" ganha a exceção documentada de descrição obsoleta após DDL, com erro e invalidação; o requisito "Busca em lotes" muda o limite de requisições para refletir lote maior.
- `gateway-protocol`: `PREPARE` aceita id de comando escolhido pelo cliente, e `EXECUTE` no mesmo lote de um `PREPARE` adiado valida a descrição; `FETCH`/`EXECUTE` limitam o lote por linhas e por bytes.
- `firebird-http-gateway`: o log de cada requisição informa o tempo gasto dentro do `libfbclient`, separado do tempo total; o limite de lote por bytes entra na configuração.

## Impact

- `client/src/fbhttp.Client.pas`: cache de preparação por `TFbAttachment`, rastreio de escrita por `TFbTransaction`, adiamento de `COMMIT`/`ROLLBACK`, descarga de operações adiadas no keep-alive e no `detach`, contadores de requisição no log de diagnóstico.
- `client/src/fbhttp.Transport.pas`: contagem e duração de requisições para o log.
- `client/src/fbhttp.Config.pas`, `client/ws-fbclient/ws-fbclient.example.ini`: chaves `prepare_cache` (tamanho, 0 desliga), `defer_readonly_commit` (liga/desliga), `fetch_rows` com padrão novo.
- `gateway/internal/server/ops.go`, `session.go`: id de comando escolhido pelo cliente, validação de descrição no `EXECUTE` após `PREPARE` adiado, limite de lote por bytes, tempo no `libfbclient` por requisição.
- `gateway/internal/config/config.go`, `docker-compose.yml`, `.env.example`: `FBHTTP_MAX_BATCH_BYTES`.
- `docs/protocol.md`, `docs/client-setup.md`, `docs/deploy.md`, `docs/performance.md` (novo).
- `client/compare/fbcompare.dpr` e `compare.bat`: contagem de requisições por etapa.
- Compatibilidade: **BREAKING** no protocolo. A versão passa a 2 (id de comando do cliente, descrição esperada no `EXECUTE`, lote limitado por bytes) e a versão 1 deixa de ser aceita: não há nada em produção. DLL e gateway sobem juntos; uma DLL de versão diferente recebe o erro de versão já existente. Nenhuma mudança na aplicação Delphi nem no driver Devart.
- Risco funcional assumido: após DDL que muda colunas ou parâmetros de um SQL em cache, a aplicação recebe um erro uma única vez nesse comando (em vez de ver a descrição nova direto). Em ERP com schema estável isso é raro, e as duas otimizações podem ser desligadas no `.ini`.
