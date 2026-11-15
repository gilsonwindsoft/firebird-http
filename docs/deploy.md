# Implantação do gateway com Docker e nginx

O gateway roda num container Linux x86-64, perto do Firebird (3, 4 ou 5). Ele atende HTTP simples. O TLS fica com um nginx na frente dele. A imagem já inclui o `libfbclient` (Firebird 4.0, Debian trixie), que fala com servidores 3, 4 e 5.

```
estação (ws-fbclient.dll) --HTTPS--> nginx :443 --HTTP--> gateway 127.0.0.1:8080 --> Firebird :3050
```

## Requisitos

- Docker Engine 24+ com o plugin `docker compose`.
- nginx com certificado TLS válido para o nome público do gateway (por exemplo, Let's Encrypt).
- Acesso de rede do container ao Firebird (porta 3050).
- **Gateway no mesmo host do Firebird**, ou numa rede com menos de 1 ms até ele. Cada requisição da estação vira de 5 a 10 chamadas ao `libfbclient`, e cada uma paga a latência entre gateway e Firebird. Em outra zona ou datacenter (2 ms), isso soma 10 a 20 ms por requisição que nenhuma otimização da DLL recupera. Confira pelo `fb_ms` do log (seção Operação).

## Instalação

```bash
git clone <este repositório> fbhttp && cd fbhttp
cp .env.example .env
nano .env                  # FBHTTP_FIREBIRD_HOST = servidor Firebird
```

A configuração vem de variáveis de ambiente, num `.env` ao lado do `docker-compose.yml` ou na tela de variáveis do Coolify:

| Variável | Uso |
|---|---|
| `FBHTTP_FIREBIRD_HOST` | **Obrigatória.** Servidor Firebird (`host` ou `host/porta`). O `Database` que a estação manda (caminho ou alias do `databases.conf`) é aberto nesse servidor. O host que vem na frente (`localhost:`, `servidor/3050:`) é ignorado. Pedidos com um segundo host, UNC (`\\host\...`) ou URL (`inet://`) são recusados. |
| `FBHTTP_ALIASES_FILE` | Opcional. Caminho, dentro do container, do arquivo de aliases: nomes que vão para outro servidor ou caminho. Use `/config/aliases.conf`. Os aliases têm prioridade sobre `FBHTTP_FIREBIRD_HOST`. Veja [Aliases](#aliases). |
| `FBHTTP_CONFIG_DIR` | Pasta do host montada em `/config` no container (padrão `./config`, ao lado do `docker-compose.yml`). Só é usada pelo `docker-compose.yml`. |
| `FBHTTP_TRUSTED_PROXIES` | Endereços (IP ou CIDR, separados por vírgula) do proxy reverso. Só deles o gateway aceita o cabeçalho `X-Real-IP` com o IP real da estação. Padrão: `127.0.0.1,172.16.0.0/12,10.0.0.0/8`, que cobre nginx no mesmo host e o proxy do Coolify (redes do Docker). |
| `FBHTTP_MAX_SESSIONS`, `FBHTTP_MAX_SESSIONS_PER_IP` | Limites de conexões simultâneas (padrão 500 e 50). O limite por IP usa o IP real da estação. |
| `FBHTTP_IDLE_TIMEOUT_SECONDS` | Sessão sem atividade é encerrada com rollback (padrão 600). Uma estação que cai no meio de uma transação segura os locks dela até esse tempo. Mantenha acima do dobro do `keepalive_seconds` da DLL (padrão 120). |
| `FBHTTP_MAX_FETCH_ROWS`, `FBHTTP_MAX_INLINE_BLOB`, `FBHTTP_MAX_BODY_BYTES` | Limites de lote (5000 linhas), BLOB embutido (1 MB) e tamanho da requisição (64 MB). Para usar, acrescente no `environment` do `docker-compose.yml`. |
| `FBHTTP_MAX_BATCH_BYTES` | Um lote de linhas para antes de `fetch_rows` quando chega a esse tamanho (padrão 4 MB, antes do gzip), com pelo menos uma linha. Limita a memória por cursor no gateway e na estação. |
| `FBHTTP_SET_BIND` | Enviado como `isc_dpb_set_bind` (Firebird 4+). Padrão: `int128 to legacy;decfloat to legacy;time zone to legacy`, para que FB 4/5 devolvam os tipos de FB 3 (`BIGINT`, `DOUBLE`, `TIMESTAMP`) que drivers antigos entendem. `none` desliga. Para usar, acrescente no `environment`. |

Restrinja no Firebird o que pode ser aberto. No `firebird.conf`, use `DatabaseAccess = Restrict /caminho/dos/dados` (ou `None`, para aceitar só aliases do `databases.conf`). Sem isso, um usuário com senha válida pode abrir qualquer `.fdb` que o servidor Firebird alcança.

`FBHTTP_PLAIN_HTTP=true` e `FBHTTP_LISTEN=:8080` já vêm fixos no `docker-compose.yml`: o TLS fica no proxy reverso.

Se o Firebird estiver no mesmo host do Docker, use o IP do host ou `host.docker.internal` (adicione `extra_hosts: ["host.docker.internal:host-gateway"]` ao serviço).

Suba o gateway:

```bash
docker compose up -d --build
docker compose ps          # STATUS deve ficar "healthy"
curl -i http://127.0.0.1:8080/healthz   # 204
```

## Aliases

Aliases publicam nomes que vão para outro servidor Firebird ou outro caminho. Eles ficam num arquivo, um por linha:

```
# comentário
erp     = 10.0.0.6:/firebird/data/erp.fdb
teste   = 10.0.0.6:erp_teste
filial2 = 10.0.0.7/3051:/dados/erp.fdb
```

O nome não pode ter `:`, `/` ou `\`, e não pode se repetir.

Para ativar:

```bash
cp config/aliases.conf.example config/aliases.conf
nano config/aliases.conf
echo 'FBHTTP_ALIASES_FILE=/config/aliases.conf' >> .env
docker compose up -d
```

Para guardar o arquivo em outra pasta do servidor, defina `FBHTTP_CONFIG_DIR` no `.env` (por exemplo `FBHTTP_CONFIG_DIR=/srv/fbhttp/config`). O `docker-compose.yml` monta essa pasta em `/config`, só leitura. Monte sempre a pasta, não o arquivo sozinho: editores e `sed -i` salvam criando um arquivo novo, e uma montagem de arquivo único continua mostrando o conteúdo antigo.

Incluir ou remover servidores:

- Edite o arquivo. O gateway o relê a cada 60 segundos, sem reinício e sem novo deploy. O log mostra `aliases reloaded` com os nomes incluídos e removidos.
- Um alias novo pode levar até 60 segundos para aceitar conexões. Um alias removido continua aceitando conexões novas pelo mesmo tempo.
- Remover um alias não derruba quem já está conectado nele. Essas sessões seguem até a estação fechar a conexão ou até `FBHTTP_IDLE_TIMEOUT_SECONDS`.
- Se o arquivo ficar inválido (linha sem `=`, nome repetido ou com `:`), o gateway mantém os aliases anteriores e registra `aliases reload failed` com o número da linha. Corrija o arquivo; a próxima leitura aplica.
- Na inicialização, um arquivo inexistente ou inválido impede o gateway de subir.
- Um script que gera o arquivo deve gravar num arquivo temporário na mesma pasta e renomear, para o gateway nunca ler um arquivo pela metade.

A consulta aos aliases só acontece quando uma estação abre a conexão. Consultas, fetch e commit não a usam. A releitura do arquivo a cada 60 segundos não tem custo perceptível, mesmo com centenas de aliases.

**Migração de `FBHTTP_ALIASES`:** a variável foi removida. Se ela ainda estiver definida, o gateway a ignora e registra um aviso no log. Antes de atualizar a imagem, copie as entradas dela para `config/aliases.conf`, uma por linha (troque cada `;` por uma quebra de linha), apague `FBHTTP_ALIASES` do `.env` e defina `FBHTTP_ALIASES_FILE=/config/aliases.conf`.

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
- `client_max_body_size 64m`: igual a `FBHTTP_MAX_BODY_BYTES`.
- `proxy_http_version 1.1` e `Connection ""`: mantêm a conexão com o gateway aberta entre requisições.

A porta 8080 é publicada em todas as interfaces do servidor. Assim, um nginx instalado no servidor usa `proxy_pass http://127.0.0.1:8080`, e um nginx em container usa `proxy_pass http://172.17.0.1:8080`. **A porta publicada pelo Docker ignora o `ufw`:** bloqueie a 8080 no firewall externo (da nuvem ou do roteador). Sem isso, o gateway fica acessível pela internet em HTTP sem TLS.

Se o nginx estiver em outro host, publique a porta como `"8080:8080"` no `docker-compose.yml`, libere no firewall só para o IP do nginx e coloque esse IP em `FBHTTP_TRUSTED_PROXIES`.

Teste a partir de outra máquina: `curl -i https://gateway.exemplo.com.br/healthz` deve responder `204`.

## Coolify

1. Crie um recurso do tipo **Docker Compose** apontando para este repositório (branch `main`, arquivo `docker-compose.yml`).
2. Em **Environment Variables**, defina `FBHTTP_FIREBIRD_HOST` (e as opcionais, se precisar).
   Para aliases, defina `FBHTTP_ALIASES_FILE=/config/aliases.conf`. O Coolify ignora `FBHTTP_CONFIG_DIR`: ele troca o caminho do volume por `/data/coolify/applications/<uuid>/config` antes de ler as variáveis, e a origem não pode ser editada em **Persistent Storage**. Coloque o `aliases.conf` nessa pasta, ou use um caminho fixo no compose que o Coolify lê. Edite o arquivo pelo SSH; o gateway aplica em até 60 segundos, sem novo deploy.
3. No serviço `gateway`, defina o domínio com a porta do container: `https://gateway.exemplo.com.br:8080`. O proxy do Coolify cuida do certificado e encaminha para a porta 8080.
4. Faça o deploy. O container deve ficar "healthy" e `https://gateway.exemplo.com.br/healthz` deve responder `204`.

O proxy do Coolify (Traefik) já envia `X-Real-IP` e não corta respostas demoradas por padrão. Se houver um nginx na frente do Coolify, ele precisa das mesmas configurações da seção nginx acima.

## Operação

- **Atualizar:** `git pull && docker compose up -d --build`. O `stop_grace_period` (40 s) deixa o gateway fazer rollback das transações abertas e desconectar antes de sair.
- **Parar:** `docker compose down`. Sessões abertas recebem rollback; os clientes recebem "conexão perdida" e reconectam.
- **Logs:** `docker compose logs -f`. Log JSON com sessões, erros e duração das requisições. Rotação já configurada (5 × 20 MB). Senhas, tokens e valores de parâmetros SQL nunca aparecem no log.
- **Rede ou banco?** Cada requisição gera uma linha `"msg":"request"` com `"ops"` (operações do lote), `"ms"` (tempo total no gateway) e `"fb_ms"` (tempo dentro das operações, quase todo no `libfbclient`):

  ```json
  {"msg":"request","session":"a1b2c3d4","seq":12,"ops":[10,20,22],"error":false,"ms":9,"fb_ms":8}
  ```

  `fb_ms` alto é o Firebird (SQL lento) ou a distância entre gateway e Firebird. `ms - fb_ms` alto é HTTP, gzip ou fila da sessão. O tempo que a estação mede (`FBHTTP_DEBUG_LOG`, `ms=`) menos o `ms` do gateway é a latência da internet. Ver [performance.md](performance.md).
- **Firewall:** exponha só a porta 443 do nginx. As portas 8080 do gateway e 3050 do Firebird não precisam ficar acessíveis de fora.

## Rollback (voltar à conexão direta)

Nas estações, volte a usar o `fbclient.dll` nativo e o `Database` original (veja [client-setup.md](client-setup.md#rollback-voltar-à-conexão-direta)). O gateway pode continuar rodando ou ser parado com `docker compose down`.

## Ambiente de teste

```bash
# Firebird 5 + gateway em HTTP simples (porta 8080, sem nginx) + testes de integração
FB_VERSION=5 docker compose -f docker-compose.test.yml run --rm tests
FB_VERSION=5 docker compose -f docker-compose.test.yml up -d firebird gateway

# Firebird 3 ou 4 (imagens só amd64; em Apple Silicon: colima start --vz-rosetta)
FB_PLATFORM=linux/amd64 FB_VERSION=4 docker compose -f docker-compose.test.yml run --rm tests
```

Sem nginx, a estação precisa de `allow_plain_http=1` no `ws-fbclient.ini` e `url=http://<host>:8080`. Use só em rede de teste.
