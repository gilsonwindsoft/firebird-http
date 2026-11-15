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
| `docs/` | `deploy.md` (servidor), `client-setup.md` (estação), `protocol.md` (protocolo), `api-surface.md` (funções usadas pelo driver), `performance.md` (medição) |
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

Copie a `ws-fbclient.dll` para a pasta da aplicação, informe o gateway (no `Database`, como `fb.windsoft.me:ws-windsoft`, ou em `url=` no `ws-fbclient.ini`) e faça a aplicação carregar a DLL (`VendorLib=ws-fbclient.dll`, ou a DLL renomeada para `fbclient.dll` na pasta da aplicação).

Passo a passo, tabela de `Database`, erros comuns e rollback: [docs/client-setup.md](docs/client-setup.md).

## Limitações

- Só Windows 32 bits, só API legada `isc_*`. A API orientada a objetos do Firebird 3+ (`fb_get_master_interface`) não existe na DLL.
- Implementado: conexão, transações, DSQL, BLOB, mensagens de erro, funções de data e auxiliares. São as funções usadas pelo driver Devart e pelo IBExpert (ver [docs/api-surface.md](docs/api-surface.md)).
- Não implementado: eventos (`isc_que_events`), API de serviços (backup, usuários), arrays, criação de banco. Essas funções devolvem o erro `not supported by ws-fbclient`.
- Cada chamada que vai à rede custa uma ida e volta HTTPS. A DLL agrupa as chamadas e lembra os comandos já preparados: um `SELECT` repetido com commit custa 1 requisição, um `INSERT`/`UPDATE` repetido com commit custa 2, um SQL novo custa 2 (ver [docs/performance.md](docs/performance.md) para medir e [docs/client-setup.md](docs/client-setup.md) para o que o cache muda).

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
