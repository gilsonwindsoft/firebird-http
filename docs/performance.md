# Medição de desempenho

O custo de um comando numa rede com latência é o número de idas e voltas ao
gateway, não o volume de dados. Este roteiro mede, por etapa do `fbcompare`
e nas telas da aplicação real, três números: tempo total, requisições HTTP e
tempo de rede. Os dois últimos vêm dos contadores da `ws-fbclient.dll`
(export `ws_fbclient_stats`, lidos pelo `fbcompare`; e o log
`FBHTTP_DEBUG_LOG`, uma linha `req seq=... ops=... ms=...` por requisição).

## Roteiro

Rode `client\compare\compare.bat` (ver `client/compare/README.md`) em três
cenários, com o mesmo banco e os mesmos parâmetros de conexão da aplicação:

| Cenário | Como |
|---|---|
| `local` | estação e gateway na mesma rede local (< 1 ms) |
| `30ms` | 30 ms simulados nos dois caminhos (3050 e 8080): `clumsy` na estação ou `tc qdisc ... netem delay 30ms` no host Linux |
| `nuvem` | gateway de produção, por HTTPS, de uma estação real |

Em cada cenário o `*.timing.txt` da execução `http` traz `ms`, `req` e
`net ms` por etapa; o da execução `native` só traz `ms`.

Para a aplicação real: defina `FBHTTP_DEBUG_LOG=C:\temp\ws-fbclient.log`,
abra as telas principais e conte as linhas `req seq=` e some os `ms=` por
tela. No gateway, a linha de log `request` traz `ms` (total) e `fb_ms`
(tempo dentro das operações, quase todo no `libfbclient`): `ms - fb_ms`
alto com `fb_ms` baixo é rede ou fila; `fb_ms` alto é o Firebird ou a
distância entre gateway e Firebird (ver `docs/deploy.md`).

## Base (antes do cache de preparação e do commit adiado)

Medir com a DLL e o gateway no estado do grupo 1 de
`openspec/changes/one-roundtrip-per-statement/tasks.md` (protocolo 1).
Preencher a tabela: tempo nativo, tempo HTTP, requisições e ms de rede.

| Etapa | local nativo | local http | local req | 30ms nativo | 30ms http | 30ms req | nuvem nativo | nuvem http | nuvem req |
|---|---|---|---|---|---|---|---|---|---|
| connect | | | | | | | | | |
| metadata | | | | | | | | | |
| types direct | | | | | | | | | |
| types clientdataset | | | | | | | | | |
| aggregates | | | | | | | | | |
| params | | | | | | | | | |
| procedure select | | | | | | | | | |
| procedure execute | | | | | | | | | |
| fetch 10000 rows | | | | | | | | | |
| transactions | | | | | | | | | |
| clientdataset applyupdates | | | | | | | | | |
| blob 2 MB roundtrip | | | | | | | | | |
| total | | | | | | | | | |

Telas da aplicação real (requisições e ms de rede por tela, do `FBHTTP_DEBUG_LOG`):

| Tela | req | net ms | tempo percebido |
|---|---|---|---|
| | | | |

## Depois (padrões novos: `prepare_cache=256`, `defer_readonly_commit=1`, `fetch_rows=5000`)

Mesmas tabelas, mesmos cenários. Esperado por comando típico: `SELECT`
repetido com commit, 1 requisição; `INSERT/UPDATE` repetido com commit, 2.

| Etapa | local nativo | local http | local req | 30ms nativo | 30ms http | 30ms req | nuvem nativo | nuvem http | nuvem req |
|---|---|---|---|---|---|---|---|---|---|
| | | | | | | | | | |

Para reproduzir o "antes" com a DLL nova: `prepare_cache=0`,
`defer_readonly_commit=0` e `fetch_rows=1000` no `ws-fbclient.ini`.
