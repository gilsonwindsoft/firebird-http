# Teste de comparação (tarefas 7.1 e 7.3)

`fbcompare.exe` roda o mesmo roteiro pelo `TSQLConnection` com o driver Devart e grava um texto determinístico. O roteiro cobre tipos, NULL, BLOB, parâmetros, procedures, erros, transações, `TClientDataSet.ApplyUpdates`, `GetTableNames` e `GetFieldNames`. O `compare.bat` roda o roteiro com o `fbclient.dll` nativo e com a `ws-fbclient.dll` e compara as duas saídas com `fc`. Os tempos de cada passo ficam em `*.timing.txt` e não entram na comparação.

## 1. Banco de teste (por versão do Firebird)

No Mac/Linux, na raiz do repositório:

```bash
FB_VERSION=5 docker compose -f docker-compose.test.yml up -d --build firebird gateway
docker compose -f docker-compose.test.yml exec -T firebird \
  isql -user SYSDBA -password masterkey /var/lib/firebird/data/test.fdb < tests/schema.sql
# só FB 4 e 5:
docker compose -f docker-compose.test.yml exec -T firebird \
  isql -user SYSDBA -password masterkey /var/lib/firebird/data/test.fdb < tests/schema-fb4.sql
```

FB 3 e 4 são só amd64. No Apple Silicon: `colima start --vz-rosetta` e `FB_PLATFORM=linux/amd64`. Para trocar de versão: `docker compose -f docker-compose.test.yml down -v` e repita com outro `FB_VERSION`.

## 2. Build (Windows, "RAD Studio Command Prompt")

```bat
cd client\ws-fbclient && build.bat
set DEVART_DBX=C:\caminho\Devart\dbExpress\InterBase\Lib\Delphi26
cd ..\compare && build.bat
```

`DEVART_DBX` é a pasta com `DbxDevartInterBase.dcu` da instalação Devart, na versão do Delphi usada.

## 3. Rodar

`HOST` é o IP da máquina que roda o Docker.

```bat
set NATIVE_FBCLIENT=C:\caminho\da\aplicacao\fbclient.dll
set DRIVER_DLL=C:\caminho\da\aplicacao\dbexpida40.dll
set WS_INI=%CD%\test.ini
compare.bat fb5 HOST/3050:/var/lib/firebird/data/test.fdb localhost:test
```

`test.ini` (rede de teste, HTTP sem TLS):

```ini
[gateway]
url=http://HOST:8080
allow_plain_http=1
```

Parâmetros extras do `TSQLConnection` vão no fim, como na aplicação real (por exemplo `Charset=WIN1252`). Use os mesmos parâmetros da aplicação.

Resultado: `SAME` ou `DIFFERENT` com o `run\<label>\diff.txt`. Repita para `fb3`, `fb4` e `fb5`. Linhas `FAIL` na saída indicam erro nas duas pontas (por exemplo, BLOB que voltou diferente).

Diferenças esperadas que não são erro: o texto de algumas mensagens de erro pode mudar se o `fbclient.dll` nativo for de outra versão que o cliente do gateway (Firebird 4). Confira se o código e o sentido são os mesmos.

## 4. Latência simulada (tarefa 7.3)

Simule 30 ms nos dois caminhos (3050 e 8080), para a comparação ser justa. Opções:

- No host Linux do Docker: `sudo tc qdisc add dev <interface> root netem delay 30ms`. Para remover: `sudo tc qdisc del dev <interface> root`.
- Na estação Windows: [clumsy](https://jagt.github.io/clumsy/) com o filtro `outbound and (tcp.DstPort == 3050 or tcp.DstPort == 8080)` e "Lag" de 30 ms.

Depois rode `compare.bat fb5-30ms ...` e compare os `*.timing.txt` de `fb5` e `fb5-30ms`. Para ajustar lote e BLOB embutido, mude `fetch_rows` e `inline_blob_bytes` no `test.ini` e rode de novo com outro label. Registre os números em `docs/performance.md`.
