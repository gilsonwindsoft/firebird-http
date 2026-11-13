# Implantação do gateway com Docker

O gateway roda num container Linux x86-64 ao lado do Firebird (3, 4 ou 5). A imagem já inclui o `libfbclient` (Firebird 4.0, Debian trixie), que fala com servidores 3, 4 e 5.

## Requisitos

- Docker Engine 24+ com o plugin `docker compose`.
- Acesso de rede do container ao Firebird (porta 3050).
- Certificado TLS para o nome público do gateway (`server.crt` com a cadeia completa e `server.key`, em PEM).

## Instalação

```bash
git clone <este repositório> fbhttp && cd fbhttp
cp deploy/config.example.json deploy/config.json
cp /caminho/server.crt /caminho/server.key deploy/certs/
chmod 644 deploy/certs/server.key   # o container roda como usuário sem privilégios (uid 10001)
```

Edite `deploy/config.json`:

| Campo | Uso |
|---|---|
| `aliases` | Nome publicado → string de conexão real (`host:/caminho/banco.fdb` ou alias do `databases.conf`). Os clientes só conseguem abrir os nomes desta lista. |
| `listen` | Endereço e porta no container (padrão `:8443`). |
| `tls_cert`, `tls_key` | Caminhos dentro do container (`/etc/fbhttp/certs/...`). |
| `plain_http` | `true` só atrás de um proxy reverso com TLS ou em rede de teste. |
| `max_sessions`, `max_sessions_per_ip` | Limites de conexões simultâneas. |
| `idle_timeout_seconds` | Sessão sem atividade é encerrada com rollback (padrão 1800). |
| `max_fetch_rows`, `max_inline_blob`, `max_body_bytes` | Limites de lote, BLOB embutido e tamanho da requisição. |
| `set_bind` | Enviado como `isc_dpb_set_bind` (Firebird 4+). Padrão: `int128 to legacy;decfloat to legacy;time zone to legacy`, para que FB 4/5 devolvam os tipos de FB 3 (`BIGINT`, `DOUBLE`, `TIMESTAMP`) que drivers antigos entendem. `""` desliga. Se o cliente mandar o próprio `set_bind`, o dele vale. |

Qualquer campo pode ser sobrescrito por variável `FBHTTP_*` no `docker-compose.yml` (ex.: `FBHTTP_ALIASES: "erp=fbserver:/data/erp.fdb;teste=fbserver:/data/teste.fdb"`).

Se o Firebird estiver no mesmo host do Docker, use o IP do host ou `host.docker.internal` (adicione `extra_hosts: ["host.docker.internal:host-gateway"]` ao serviço).

Suba:

```bash
docker compose up -d --build
docker compose ps          # STATUS deve ficar "healthy"
docker compose logs -f     # log JSON: sessões, erros, duração das requisições
```

Teste a partir de outra máquina: `curl -I https://gateway.exemplo.com.br:8443/healthz` deve responder `204`.

## Operação

- **Atualizar:** `git pull && docker compose up -d --build`. O `stop_grace_period` (40 s) deixa o gateway fazer rollback das transações abertas e desconectar antes de sair.
- **Parar:** `docker compose down`. Sessões abertas recebem rollback; os clientes recebem "conexão perdida" e reconectam.
- **Logs:** rotação já configurada (5 × 20 MB). Senhas, tokens e valores de parâmetros SQL nunca aparecem no log.
- **Firewall:** exponha só a porta do gateway. A porta 3050 do Firebird não precisa ficar acessível de fora.

## Rollback (voltar à conexão direta)

Nas estações, volte `VendorLib` para `fbclient.dll` e `Database` para o caminho original. O gateway pode continuar rodando ou ser parado com `docker compose down`.

## Ambiente de teste

```bash
# Firebird 5 + gateway em HTTP simples (porta 8080) + testes de integração
FB_VERSION=5 docker compose -f docker-compose.test.yml run --rm tests
FB_VERSION=5 docker compose -f docker-compose.test.yml up -d firebird gateway

# Firebird 3 ou 4 (imagens só amd64; em Apple Silicon: colima start --vz-rosetta)
FB_PLATFORM=linux/amd64 FB_VERSION=4 docker compose -f docker-compose.test.yml run --rm tests
```
