# fbhttp: Firebird por HTTP para aplicações Delphi

Permite que uma aplicação Delphi 32 bits com dbExpress acesse o Firebird pela internet, por HTTPS, sem expor a porta 3050 e sem mudar o código da aplicação.

```
TSQLConnection -> driver dbExpress (Devart) -> ws-fbclient.dll --HTTPS--> nginx -> gateway (Docker) -> Firebird 3/4/5
```

- **`ws-fbclient.dll`** (Delphi, Win32): substitui o `fbclient.dll` para a aplicação. Exporta a API `isc_*` que o driver usa e manda as chamadas ao gateway em lote, por HTTP.
- **Gateway** (Go, Linux, Docker): recebe as chamadas e as executa no Firebird com o `fbclient` real. Cada conexão da estação é uma sessão no gateway, com suas transações.
- **nginx**: faz o TLS na frente do gateway.

O nome `ws-fbclient.dll` permite que ela fique na mesma máquina que o `fbclient.dll` nativo.

## Estrutura

| Pasta | Conteúdo |
|---|---|
| `gateway/` | Código do gateway e `Dockerfile` |
| `deploy/` | `nginx.example.conf` |
| `.env.example` | Variáveis do gateway (`FBHTTP_FIREBIRD_HOST` e opcionais) |
| `client/src/` | Código da `ws-fbclient.dll` |
| `client/ws-fbclient/` | Projeto, `build.bat` e `ws-fbclient.example.ini` |
| `client/tests/` | Testes DUnitX da DLL |
| `client/proxy/` | Proxy de log do `fbclient.dll`, para descobrir quais funções uma aplicação chama |
| `docs/` | `deploy.md` (servidor), `protocol.md` (protocolo), `api-surface.md` (funções usadas pelo driver) |
| `tests/` | Schemas SQL usados pelos testes de integração |

## 1. Subir o servidor

No servidor Linux, com Docker e nginx:

```bash
git clone <este repositório> fbhttp && cd fbhttp
cp .env.example .env
nano .env                      # FBHTTP_FIREBIRD_HOST = servidor Firebird
docker compose up -d --build
docker compose ps              # STATUS "healthy"
```

`FBHTTP_FIREBIRD_HOST` é o servidor Firebird visto do container (`10.0.0.5` ou `10.0.0.5/3050`). O gateway abre nele o banco que a estação pede, seja caminho ou alias do `databases.conf`, e ignora o host que a estação manda na frente. Para limitar o que pode ser aberto, use `DatabaseAccess = Restrict /caminho/dos/dados` no `firebird.conf`.

Configure o nginx a partir de `deploy/nginx.example.conf`: troque o `server_name` e os caminhos do certificado, depois rode `nginx -t && systemctl reload nginx`.

Confira de outra máquina:

```bash
curl -i https://gateway.exemplo.com.br/healthz    # HTTP/2 204
```

No Coolify, em vez do `.env`, defina `FBHTTP_FIREBIRD_HOST` na tela de variáveis e o domínio do serviço `gateway` com a porta 8080. O proxy do Coolify faz o TLS no lugar do nginx.

Detalhes (todas as variáveis, nginx, Coolify, atualização, logs): [docs/deploy.md](docs/deploy.md).

## 2. Compilar a DLL

Num "RAD Studio Command Prompt" (Delphi 10.x a 12):

```bat
cd client\ws-fbclient
build.bat
```

Saída: `client\bin\ws-fbclient\ws-fbclient.dll` (Win32) e `ws-fbclient.example.ini`.

## 3. Conectar uma estação

### 3.1 Copie a DLL e diga onde está o gateway

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

Se existir `url` no `.ini` (ou na variável `FBHTTP_URL`), ela vale. Os outros itens do `.ini` (timeouts, `fetch_rows`, `inline_blob_bytes`) têm padrão e podem ficar de fora.

### 3.2 Aponte a aplicação para a DLL

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

### 3.3 O `Database`

O gateway descarta o servidor que vem na frente e abre o resto no `FBHTTP_FIREBIRD_HOST`:

| `Database` na estação | Gateway chamado | Aberto pelo gateway |
|---|---|---|
| `fb.windsoft.me:ws-windsoft` (sem `.ini`) | `https://fb.windsoft.me` | `FIREBIRD_HOST:ws-windsoft` (alias do `databases.conf`) |
| `localhost:ws-windsoft` (com `.ini`) | `url` do `.ini` | `FIREBIRD_HOST:ws-windsoft` |
| `servidor/3050:/dados/erp.fdb` (com `.ini`) | `url` do `.ini` | `FIREBIRD_HOST:/dados/erp.fdb` |
| `erp` (com `.ini`, nome em `FBHTTP_ALIASES`) | `url` do `.ini` | o destino configurado para `erp` |

Usuário, senha, role e charset continuam os mesmos do Firebird. O gateway os repassa ao servidor.

### 3.4 Teste

Abra a aplicação. No servidor, `docker compose logs -f` deve mostrar `session open` com o usuário, o alias e o IP da estação.

| Erro na estação | Causa |
|---|---|
| `ws-fbclient: gateway URL not configured` | O `Database` não tem servidor (`servidor:banco`) e não há `ws-fbclient.ini` com `url=` na pasta da DLL. |
| Erro de rede ou "conexão perdida" | URL errada, nginx parado ou porta 443 bloqueada. Teste o `/healthz` no navegador da estação. |
| Erro de certificado | O certificado do nginx não é confiável para o Windows. Use um certificado válido. |
| `database ... is not allowed by this gateway` | O `Database` tem um segundo host, caminho UNC ou URL (`inet://`). Use `servidor:caminho` ou `servidor:alias`. |
| Banco não encontrado (erro do Firebird) | O caminho ou alias não existe no `FBHTTP_FIREBIRD_HOST`, ou o `DatabaseAccess` do Firebird não permite. |
| `not supported by ws-fbclient` | A aplicação chamou uma função que a DLL não implementa (ver Limitações). |

Para diagnóstico na estação, defina a variável de ambiente `FBHTTP_DEBUG_LOG=C:\temp\ws-fbclient.log` antes de abrir a aplicação. O log mostra as chamadas e os tempos, sem dados nem senhas.

## Limitações

- Só Windows 32 bits, só API legada `isc_*`. A API orientada a objetos do Firebird 3+ (`fb_get_master_interface`) não existe na DLL.
- Implementado: conexão, transações, DSQL, BLOB, mensagens de erro, funções de data e auxiliares. São as funções usadas pelo driver Devart e pelo IBExpert (ver [docs/api-surface.md](docs/api-surface.md)).
- Não implementado: eventos (`isc_que_events`), API de serviços (backup, usuários), arrays, criação de banco. Essas funções devolvem o erro `not supported by ws-fbclient`.
- Cada chamada que vai à rede custa uma ida e volta HTTPS. A DLL agrupa as chamadas para que um comando típico custe 3 requisições.

## Desenvolvimento

Gateway (testes de integração contra Firebird num container):

```bash
FB_VERSION=5 docker compose -f docker-compose.test.yml run --rm tests
```

Para testar estações sem nginx, suba o gateway de teste em HTTP na porta 8080 (`docker compose -f docker-compose.test.yml up -d firebird gateway`) e use no `.ini` `url=http://<host>:8080` com `allow_plain_http=1`. Só em rede de teste.

DLL (DUnitX), num "RAD Studio Command Prompt":

```bat
cd client\tests
build.bat
```

Se os exports de `client/src/fbhttp.Client.pas` mudarem, gere o projeto de novo com `python3 client/tools/gen_wsfbclient.py`.

O protocolo entre DLL e gateway está em [docs/protocol.md](docs/protocol.md).
