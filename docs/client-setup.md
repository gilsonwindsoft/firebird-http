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

Se existir `url` no `.ini` (ou na variável `FBHTTP_URL`), ela vale. Os outros itens do `.ini` (timeouts, `fetch_rows`, `inline_blob_bytes`) têm padrão e podem ficar de fora.

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
| `erp` (com `.ini`, nome em `FBHTTP_ALIASES`) | `url` do `.ini` | o destino configurado para `erp` |

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

Para diagnóstico na estação, defina a variável de ambiente `FBHTTP_DEBUG_LOG=C:\temp\ws-fbclient.log` antes de abrir a aplicação. O log mostra as chamadas e os tempos, sem dados nem senhas.

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
