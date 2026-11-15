# Configuração da estação

Como fazer uma aplicação Delphi (dbExpress, driver Devart) usar a `ws-fbclient.dll` em vez do `fbclient.dll` nativo, sem mudar o código. O gateway precisa estar no ar antes (veja [deploy.md](deploy.md)): `https://<gateway>/healthz` deve responder `204` no navegador da estação.

Você precisa de:

- `ws-fbclient.dll` (Win32), gerada por `client\ws-fbclient\build.bat` em `client\bin\ws-fbclient\`.
- `ws-fbclient.example.ini`, na mesma pasta, se for usar o `.ini`.
- O endereço HTTPS público do gateway.

## Copie a DLL e diga onde está o gateway

Copie a `ws-fbclient.dll` para a **pasta da aplicação** (a pasta do `.exe`). A DLL precisa saber o endereço do gateway. Há dois jeitos:

**A. Pelo `Database` da conexão (sem `.ini`).** Use o endereço do gateway como servidor:

```ini
Database=fb.windsoft.me:ws-windsoft
```

A DLL chama `https://fb.windsoft.me` e o gateway abre `ws-windsoft` no Firebird dele. Uma porta no `Database` (`fb.windsoft.me/3151:...`) é ignorada: o HTTPS usa sempre a 443.

**B. Pelo `ws-fbclient.ini` (o `Database` não muda).** Crie o `ws-fbclient.ini` na mesma pasta da DLL, a partir de `ws-fbclient.example.ini`:

```ini
[gateway]
url=https://fb.windsoft.me
```

Sem barra no final. Com o `.ini`, o servidor que vem no `Database` é ignorado, e a aplicação pode continuar com `localhost:ws-windsoft`. Use este jeito quando não puder mudar o `Database` da aplicação.

Se existir `url` no `.ini` (ou na variável `FBHTTP_URL`), ela vale. Os outros itens do `.ini` têm padrão e podem ficar de fora. Cada um também pode vir de uma variável de ambiente `FBHTTP_<CHAVE>` em maiúsculas (`FBHTTP_PREPARE_CACHE`), que tem prioridade sobre o `.ini`.

| Chave | Padrão | O que faz |
|---|---|---|
| `connect_timeout_ms`, `response_timeout_ms` | 10000, 1800000 | Tempo para conectar ao gateway e para esperar uma resposta (um SQL demorado). |
| `fetch_rows` | 5000 | Linhas pedidas por lote. O gateway também para o lote em `FBHTTP_MAX_BATCH_BYTES` (4 MB). |
| `inline_blob_bytes` | 65536 | BLOB até esse tamanho vem inteiro na abertura. |
| `keepalive_seconds` | 120 | Ping ao gateway em conexão ociosa, para a sessão não expirar. |
| `prepare_cache` | 256 | Comandos preparados lembrados por conexão. Um SQL já visto é descrito do cache e o `PREPARE` vai junto com o `EXECUTE`: 1 requisição em vez de 2. `0` desliga. |
| `defer_readonly_commit` | 1 | `Commit`/`Rollback` de uma transação que só leu volta na hora e vai com a próxima requisição. `0` desliga. |
| `deferred_flush_ms` | 1000 | Conexão ociosa por esse tempo envia o que ficou adiado (commits, frees), para a transação não ficar aberta no Firebird. |
| `allow_plain_http`, `allow_invalid_certificate` | 0 | Só para rede de teste. |

O que o cache e o commit adiado mudam no comportamento, e quando desligar:

- **Schema alterado com SQL em cache.** Se uma tabela ou procedure muda (DDL) de forma que colunas ou parâmetros de um SQL já em cache ficam diferentes, a próxima execução desse SQL falha uma vez com `fbhttp: statement description changed` (código `isc_dsql_sqlda_err`). A DLL descarta a entrada, e a preparação seguinte do mesmo SQL vai ao gateway e traz a descrição nova. Numa aplicação que altera o schema em uso (ferramenta de atualização de banco), use `prepare_cache=0`.
- **Transação só de leitura confirmada com atraso.** O `Commit` volta antes de o gateway confirmar. A confirmação sai na próxima requisição da conexão ou em até `deferred_flush_ms`. Isso não muda o que a aplicação vê na própria conexão (as operações seguem em ordem). Muda em dois casos: uma *procedure selecionável* que grava (`SELECT ... FROM PROC`) conta como leitura e a gravação só fica confirmada na descarga; e outra conexão ou processo que leia logo após o `Commit` pode ainda não ver essa gravação. Se a aplicação tem procedures selecionáveis que gravam, use `defer_readonly_commit=0`. `INSERT`, `UPDATE`, `DELETE`, `EXECUTE PROCEDURE`, `SELECT ... FOR UPDATE`, `EXECUTE IMMEDIATE` e BLOBs gravados sempre tornam o commit síncrono.

Para voltar ao comportamento anterior sem trocar a DLL: `prepare_cache=0`, `defer_readonly_commit=0` e `fetch_rows=1000`.

## Aponte a aplicação para a DLL

A forma depende de a aplicação respeitar ou não o `VendorLib`.

**Se a aplicação respeita o `VendorLib`**, troque no `TSQLConnection` (no `.dfm`, no código ou no `dbxconnections.ini`, conforme a aplicação):

```ini
VendorLib=ws-fbclient.dll
```

O `fbclient.dll` nativo continua instalado e é usado pelas outras conexões e programas.

**Se a aplicação ignora o `VendorLib`**, como o driver Devart no `WS_SisCom`, que sempre carrega `fbclient.dll` da pasta da aplicação: com a aplicação fechada, renomeie o `fbclient.dll` da pasta da aplicação e coloque a `ws-fbclient.dll` no lugar dele, com o nome `fbclient.dll`:

```bat
cd /d C:\caminho\da\aplicacao
ren fbclient.dll fbclient_nativo.dll
copy /y ws-fbclient.dll fbclient.dll
```

Isso vale só para essa pasta. Se usar o `.ini`, ele continua com o nome `ws-fbclient.ini`, mesmo com a DLL renomeada. Para voltar: `del fbclient.dll` e `ren fbclient_nativo.dll fbclient.dll`.

**No IBExpert**, no registro do banco, preencha "Client library file" com o caminho completo da `ws-fbclient.dll`.

## O `Database`

O gateway descarta o servidor que vem na frente e abre o resto no `FBHTTP_FIREBIRD_HOST`:

| `Database` na estação | Gateway chamado | Aberto pelo gateway |
|---|---|---|
| `fb.windsoft.me:ws-windsoft` (sem `.ini`) | `https://fb.windsoft.me` | `FIREBIRD_HOST:ws-windsoft` (alias do `databases.conf`) |
| `localhost:ws-windsoft` (com `.ini`) | `url` do `.ini` | `FIREBIRD_HOST:ws-windsoft` |
| `servidor/3050:/dados/erp.fdb` (com `.ini`) | `url` do `.ini` | `FIREBIRD_HOST:/dados/erp.fdb` |
| `erp` (com `.ini`, nome no arquivo de aliases do gateway) | `url` do `.ini` | o destino configurado para `erp` |

Usuário, senha, role e charset continuam os mesmos do Firebird. O gateway os repassa ao servidor.

## Teste

Abra a aplicação. No servidor, `docker compose logs -f` deve mostrar `session open` com o usuário, o alias e o IP da estação.

| Erro na estação | Causa |
|---|---|
| `ws-fbclient: gateway URL not configured` | O `Database` não tem servidor (`servidor:banco`) e não há `ws-fbclient.ini` com `url=` na pasta da DLL. |
| Erro de rede ou "conexão perdida" | URL errada, nginx parado ou porta 443 bloqueada. Teste o `/healthz` no navegador da estação. |
| Erro de certificado | O certificado do nginx não é confiável para o Windows. Use um certificado válido. |
| `database ... is not allowed by this gateway` | O `Database` tem um segundo host, caminho UNC ou URL (`inet://`). Use `servidor:caminho` ou `servidor:alias`. |
| Banco não encontrado (erro do Firebird) | O caminho ou alias não existe no `FBHTTP_FIREBIRD_HOST`, ou o `DatabaseAccess` do Firebird não permite. |
| `not supported by ws-fbclient` | A aplicação chamou uma função que a DLL não implementa (ver [Limitações](../README.md#limitações)). |

Para diagnóstico na estação, defina a variável de ambiente `FBHTTP_DEBUG_LOG=C:\temp\ws-fbclient.log` antes de abrir a aplicação. O log tem uma linha por requisição ao gateway (`req seq=12 ops=10,20,22 out=180 in=2310 ms=41 http=200`: operações do lote, bytes enviados e recebidos, tempo de rede), sem SQL, dados nem senhas. Contar as linhas `req` de uma tela diz quantas idas e voltas ela custa; ver [performance.md](performance.md).

## Rollback (voltar à conexão direta)

Feche a aplicação e desfaça só o que foi mudado:

- **`VendorLib` trocado:** volte `VendorLib` para `fbclient.dll` (ou o valor original) e o `Database` para o servidor Firebird original (`servidor:caminho` ou `servidor:alias`).
- **DLL renomeada na pasta da aplicação:**

  ```bat
  cd /d C:\caminho\da\aplicacao
  del fbclient.dll
  ren fbclient_nativo.dll fbclient.dll
  ```

  Volte também o `Database`, se ele foi mudado para o endereço do gateway.
- **IBExpert:** limpe "Client library file" no registro do banco.

Depois, apague `ws-fbclient.dll` e `ws-fbclient.ini` da pasta, se quiser. A estação volta a precisar de acesso direto à porta 3050 do Firebird.
