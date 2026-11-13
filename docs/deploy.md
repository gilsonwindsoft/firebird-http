# Implantação do gateway com Docker e nginx

O gateway roda num container Linux x86-64, perto do Firebird (3, 4 ou 5). Ele atende HTTP simples. O TLS fica com um nginx na frente dele. A imagem já inclui o `libfbclient` (Firebird 4.0, Debian trixie), que fala com servidores 3, 4 e 5.

```
estação (ws-fbclient.dll) --HTTPS--> nginx :443 --HTTP--> gateway 127.0.0.1:8080 --> Firebird :3050
```

## Requisitos

- Docker Engine 24+ com o plugin `docker compose`.
- nginx com certificado TLS válido para o nome público do gateway (por exemplo, Let's Encrypt).
- Acesso de rede do container ao Firebird (porta 3050).

## Instalação

```bash
git clone <este repositório> fbhttp && cd fbhttp
cp deploy/config.example.json deploy/config.json
```

Edite `deploy/config.json`:

| Campo | Uso |
|---|---|
| `aliases` | Nome publicado → string de conexão real (`host:/caminho/banco.fdb` ou alias do `databases.conf`). Os clientes só conseguem abrir os nomes desta lista. |
| `listen` | Endereço e porta no container. Mantenha `:8080`, que é a porta do `docker-compose.yml`. |
| `plain_http` | Mantenha `true`. O TLS fica no nginx. |
| `trusted_proxies` | Endereços (IP ou CIDR) de onde chegam as requisições do nginx. Só delas o gateway aceita o cabeçalho `X-Real-IP` com o IP real da estação. O padrão (`127.0.0.1`, `172.16.0.0/12`) cobre nginx no mesmo host, que chega ao container pela rede do Docker. |
| `max_sessions`, `max_sessions_per_ip` | Limites de conexões simultâneas. O limite por IP usa o IP real da estação. |
| `idle_timeout_seconds` | Sessão sem atividade é encerrada com rollback (padrão 1800). |
| `max_fetch_rows`, `max_inline_blob`, `max_body_bytes` | Limites de lote, BLOB embutido e tamanho da requisição. |
| `set_bind` | Enviado como `isc_dpb_set_bind` (Firebird 4+). Padrão: `int128 to legacy;decfloat to legacy;time zone to legacy`, para que FB 4/5 devolvam os tipos de FB 3 (`BIGINT`, `DOUBLE`, `TIMESTAMP`) que drivers antigos entendem. `""` desliga. Se o cliente mandar o próprio `set_bind`, o dele vale. |

Qualquer campo pode ser sobrescrito por variável `FBHTTP_*` no `docker-compose.yml` (ex.: `FBHTTP_ALIASES: "erp=fbserver:/data/erp.fdb;teste=fbserver:/data/teste.fdb"`, `FBHTTP_TRUSTED_PROXIES: "127.0.0.1,172.16.0.0/12"`).

Se o Firebird estiver no mesmo host do Docker, use o IP do host ou `host.docker.internal` (adicione `extra_hosts: ["host.docker.internal:host-gateway"]` ao serviço).

Suba o gateway:

```bash
docker compose up -d --build
docker compose ps          # STATUS deve ficar "healthy"
curl -i http://127.0.0.1:8080/healthz   # 204
```

## nginx

Use `deploy/nginx.example.conf` como base: troque `server_name` e os caminhos do certificado.

```bash
sudo cp deploy/nginx.example.conf /etc/nginx/conf.d/fbhttp.conf
sudo nano /etc/nginx/conf.d/fbhttp.conf
sudo nginx -t && sudo systemctl reload nginx
```

Pontos que o exemplo já resolve e que não podem faltar numa configuração própria:

- `proxy_set_header X-Real-IP $remote_addr`: sem ele, todas as estações parecem vir do nginx e dividem o mesmo `max_sessions_per_ip`.
- `proxy_read_timeout 1800s`: um SQL demorado mantém a requisição aberta. Com o padrão do nginx (60 s), o cliente recebe 504.
- `client_max_body_size 64m`: igual a `max_body_bytes`.
- `proxy_http_version 1.1` e `Connection ""`: mantêm a conexão com o gateway aberta entre requisições.

Se o nginx estiver em outro host, publique a porta como `"8080:8080"` no `docker-compose.yml`, libere no firewall só para o IP do nginx e coloque esse IP em `trusted_proxies`.

Teste a partir de outra máquina: `curl -i https://gateway.exemplo.com.br/healthz` deve responder `204`.

## Operação

- **Atualizar:** `git pull && docker compose up -d --build`. O `stop_grace_period` (40 s) deixa o gateway fazer rollback das transações abertas e desconectar antes de sair.
- **Parar:** `docker compose down`. Sessões abertas recebem rollback; os clientes recebem "conexão perdida" e reconectam.
- **Logs:** `docker compose logs -f`. Log JSON com sessões, erros e duração das requisições. Rotação já configurada (5 × 20 MB). Senhas, tokens e valores de parâmetros SQL nunca aparecem no log.
- **Firewall:** exponha só a porta 443 do nginx. As portas 8080 do gateway e 3050 do Firebird não precisam ficar acessíveis de fora.

## Rollback (voltar à conexão direta)

Nas estações, volte a usar o `fbclient.dll` nativo e o `Database` original (veja o README). O gateway pode continuar rodando ou ser parado com `docker compose down`.

## Ambiente de teste

```bash
# Firebird 5 + gateway em HTTP simples (porta 8080, sem nginx) + testes de integração
FB_VERSION=5 docker compose -f docker-compose.test.yml run --rm tests
FB_VERSION=5 docker compose -f docker-compose.test.yml up -d firebird gateway

# Firebird 3 ou 4 (imagens só amd64; em Apple Silicon: colima start --vz-rosetta)
FB_PLATFORM=linux/amd64 FB_VERSION=4 docker compose -f docker-compose.test.yml run --rm tests
```

Sem nginx, a estação precisa de `allow_plain_http=1` no `ws-fbclient.ini` e `url=http://<host>:8080`. Use só em rede de teste.
