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

## Base e depois: `fbcompare`, FB3, nuvem (2026-11-15)

A DLL da versão 1 não é mais aceita pelo gateway. A base é a DLL atual com
os recursos novos desligados, o que repete o padrão de requisições da
versão 1 (PREPARE, EXECUTE e COMMIT separados; lotes de 1000 linhas):

```
set FBHTTP_PREPARE_CACHE=0
set FBHTTP_DEFER_READONLY_COMMIT=0
set FBHTTP_FETCH_ROWS=1000
compare fb3 servico.windsoft.com.br/3151:ws-cep fb.windsoft.me:ws-cep
```

As variáveis valem para o `fbcompare` filho. Parâmetros `Nome=Valor` no fim
do `compare.bat` vão para o `TSQLConnection`, não para a DLL. O "depois" é a
mesma linha com as três variáveis limpas (padrões: `prepare_cache=256`,
`defer_readonly_commit=1`, `fetch_rows=5000`). As duas execuções deram
`SAME`. Nativo direto na porta 3151 do servidor; HTTP pelo gateway.

| Etapa | base nativo ms | base http ms | base req | base net ms | depois nativo ms | depois http ms | depois req | depois net ms |
|---|---|---|---|---|---|---|---|---|
| connect | 1031 | 1374 | 6 | 1062 | 817 | 1200 | 5 | 844 |
| metadata | 385 | 255 | 6 | 235 | 379 | 104 | 4 | 77 |
| types direct | 156 | 102 | 4 | 78 | 142 | 109 | 3 | 94 |
| types clientdataset | 964 | 494 | 16 | 452 | 709 | 396 | 8 | 281 |
| aggregates | 226 | 82 | 3 | 63 | 147 | 42 | 2 | 31 |
| params | 151 | 74 | 3 | 62 | 259 | 52 | 2 | 47 |
| procedure select | 144 | 64 | 3 | 63 | 143 | 48 | 2 | 47 |
| procedure execute | 160 | 137 | 3 | 140 | 95 | 62 | 3 | 62 |
| fetch 10000 rows | 590 | 337 | 13 | 328 | 495 | 264 | 4 | 235 |
| error unknown table | 72 | 45 | 2 | 32 | 82 | 27 | 1 | 31 |
| error syntax | 67 | 121 | 2 | 125 | 144 | 19 | 1 | 16 |
| error conversion | 135 | 67 | 3 | 62 | 134 | 42 | 2 | 47 |
| transactions | 775 | 345 | 15 | 329 | 713 | 428 | 13 | 391 |
| error primary key | 93 | 162 | 3 | 141 | 176 | 72 | 3 | 78 |
| clientdataset applyupdates | 684 | 306 | 14 | 298 | 683 | 193 | 8 | 172 |
| blob 2 MB roundtrip | 351 | 195 | 3 | 62 | 449 | 312 | 3 | 172 |
| **total** | 6176 | 4274 | 103 | 3626 | 5766 | 3445 | 66 | 2687 |

Resumo: requisições de 103 para 66 (-36%), tempo HTTP de 4274 para 3445 ms.
O nativo variou entre 5766 e 6176 ms nas mesmas horas. Com os padrões, 78%
do tempo HTTP é rede (média de cerca de 40 ms por requisição): o próximo
ganho vem de cortar requisições, não de banda. O `fbcompare` roda cada SQL
uma vez, então o cache de preparação pesa pouco aqui; o efeito dele aparece
na aplicação real. Os cenários local e 30 ms simulado não foram medidos.

## Aplicação real: WS_SisCom, nuvem (2026-11-15)

`FBHTTP_DEBUG_LOG` com os padrões novos, cerca de 110 s de uso com várias
telas, quatro conexões. Contagem feita sobre as linhas `req` do log:

| Item | valor |
|---|---|
| requisições | 1072 |
| ms de rede somados | 32094 (média de 30 ms) |
| PREPARE respondido do cache, enviado com o EXECUTE | 527 requisições |
| PREPARE fora do cache (SQL usado pela primeira vez na conexão) | 127 requisições, cada uma seguida de um EXECUTE |
| COMMIT/ROLLBACK/COMMIT RETAINING adiados (carona em outra requisição) | 344 operações |
| requisições só com operações adiadas (descarga por tempo da conexão ociosa) | 22 |
| gravação de BLOB (`PUT_SEGMENTS`, `CLOSE_BLOB`, `BLOB_INFO`) | 58 |
| leitura de BLOB (`OPEN_BLOB`, `GET_SEGMENTS`) | 48 |

Estimativa do mesmo uso com o padrão da versão 1: cada acerto do cache
seria um PREPARE a mais e cada encerramento adiado seria uma requisição
própria, cerca de 1943 requisições. Os padrões novos cortam cerca de 45%,
perto de 26 s de rede nesta sessão.

O que ainda custa ida e volta, em ordem de tamanho:

- PREPARE fora do cache: a primeira vez de cada SQL em cada conexão
  (127 requisições). Um cache gravado em disco entre execuções da aplicação
  as cortaria a partir da segunda abertura.
- BLOB: gravar um BLOB custa 3 requisições e ler custa 1 a 2.
- COMMIT após gravação: síncrono por desenho, para o erro chegar à
  aplicação no commit.
