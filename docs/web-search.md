# Pesquisa na web

## Configuração

A pesquisa é independente do provedor de conversa. A primeira integração é **Exa Answer**. Google e OpenAI continuam disponíveis para a conversa, mas seus mecanismos antigos de pesquisa foram removidos desse fluxo.

No menu do Mac, passe o mouse em **Web Search** e clique em **Exa**. Isso seleciona o provedor e abre **Exa API Key**. Salve sua chave e faça uma pesquisa pelo Bluey. Clicar novamente em Exa permite substituir a chave ou usar **Remove Key**. Cancelar preserva a chave anterior e a seleção feita. Salvar vazio também preserva a chave. **Disabled** desativa a busca sem apagar credenciais.

A seleção começa desativada, inclusive em atualizações. Ela persiste no `UserDefaults`, separada de `Voice Provider`. Trocar a pesquisa não reinicia a conversa. O menu identifica a ausência de chave. A credencial Exa usa a entrada `exa` no armazenamento privado já existente em `~/Library/Application Support/Googly/keys.json`, com permissões de usuário. Não é o Keychain do macOS. A chave não vai para o repositório, iPhone ou retorno da ferramenta.

## Arquitetura

```text
web_research (cérebro OpenAI ou Gemini)
  → RealtimeHost / WebResearch (Mac: seleção e credencial)
  → WebSearchService (disponibilidade, validação e erros)
  → WebSearchProvider → Exa /answer
  ← WebSearchResult v1
  → ReportPanel + Packet.text → LiveVoice → adaptador de conversa
                                         → histórico legível / sincronização de notas
```

- `Shared/WebSearchResult.swift`: contrato serializável, apresentação legível e leitura do marcador legado.
- `Mac/Sources/WebSearch/`: biblioteca `BlueyWebSearch`, sem AppKit nem dependência das configurações de conversa. Contém a interface, serviço e adaptador Exa.
- `Mac/Sources/GooglyMac/WebResearch.swift`: registro dos provedores, seleção e acesso local à credencial; logs de metadados.
- `RealtimeHost`: executa a ferramenta e retorna JSON. As instruções para o cérebro ficam na descrição da ferramenta e em `toolRules`, separadas dos dados.
- `ReportPanel`: apresenta resposta, limitações e links, ou o erro de configuração/execução.
- `LiveVoice`: reconhece o retorno de pesquisa, salva sua apresentação legível e encaminha o JSON integral ao adaptador. Se a ferramenta não especificar idioma, adiciona o idioma de fala do iPhone antes de solicitar a pesquisa ao Mac.

## Contrato versão 1

`WebSearchRequest` contém `id`, `question`, `context` opcional, `language` e `date`. O contexto da tela é material auxiliar não confiável. O idioma aceita um identificador de idioma/localidade; valores inválidos usam inglês. Datas são transportadas em ISO 8601, com precisão de segundos.

O retorno da ferramenta é um objeto JSON com:

| Campo | Uso |
| --- | --- |
| `kind`, `version` | `web_search_result`, `1`; identificam o contrato |
| `requestID`, `provider` | Identificador local da consulta e provedor selecionado, se houver |
| `status` | `success`, `partial`, `unavailable` ou `failure` |
| `question`, `language`, `searchedAt` | Pergunta, idioma de saída e horário de referência da consulta |
| `answer` | Título de até sete palavras e um a quatro parágrafos; opcional |
| `sources` | Fontes com `id`, `title`, `url`, `excerpt` e `publishedDate` opcionais |
| `limitations` | Limitações fornecidas pelo adaptador |
| `error` | Código estável e mensagem legível, quando indisponível ou falha |
| `providerRequestID`, `costUSD` | Metadados opcionais retornados pelo provedor |

Campos opcionais ausentes são omitidos na serialização. O horário da consulta não prova a atualidade das fontes. Datas de publicação só são incluídas quando fornecidas pelo mecanismo.

`success` exige resposta válida e pelo menos uma fonte HTTP(S). O serviço normaliza links, remove fragmentos e parâmetros `utm_`, rejeita URLs sem host ou com credenciais, deduplica fontes e atribui identificadores locais. Uma resposta Exa vazia, fora do formato ou sem fontes válidas vira `failure`, sem aproveitar seu texto como resposta factual.

`partial` suporta mecanismos que devolvem apenas fontes/evidências. O balão indica que não há relatório pronto e mostra os trechos disponíveis. O cérebro pode sintetizar esses trechos; um link sem trecho não prova o conteúdo da página. Falhas e indisponibilidade sempre retornam sem resposta factual. O cérebro é instruído a explicar o erro e não substituir a pesquisa por informação de memória.

OpenAI recebe a string JSON em `function_call_output.output`; Gemini recebe a mesma string em `functionResponses[].response.result`. O transporte Mac/iPhone usa `Packet.text`; nenhum novo envelope de rede é necessário. O histórico guarda texto legível com título, parágrafos, limitações e fontes. Sessões existentes não são reescritas. O iPhone também aceita o antigo marcador `---REPORT---` vindo de Macs antigos. Um iPhone antigo não interpreta o novo JSON como relatório: atualize os dois aplicativos para esta integração.

## Adaptador Exa

Usa `POST https://api.exa.ai/answer`, cabeçalho `x-api-key`, modelo `exa`, sem streaming e sem solicitar texto completo das páginas. A pergunta e o contexto ficam em campos distintos no JSON enviado como `query`; data e idioma acompanham as instruções em `systemPrompt`. `outputSchema` solicita título e parágrafos estruturados e aceita limitações. As fontes vêm de `citations`, não de links extraídos do texto. Consulte o [contrato oficial do Exa Answer](https://exa.ai/docs/reference/answer).

O timeout é de 90 segundos. Não há repetição explícita de chamadas, fallback de provedor, validação remota ao salvar a chave ou modo de pesquisa profunda. Cada pedido configurado gera uma chamada a `/answer`. O serviço diferencia chave recusada (401/403), saldo esgotado (402), limite de requisições (429), timeout, rede, resposta inválida e falha do provedor. A chave é validada remotamente no primeiro uso.

Desativado, sem chave ou sem provedor integrado: a disponibilidade é verificada antes do carregamento e da rede. A ferramenta permanece disponível ao cérebro para que ele possa explicar a configuração necessária. Nenhum provedor alternativo é usado automaticamente.

Logs técnicos: subsistema `dev.luccabonim.bluey`, categoria `WebSearch`. Registram identificador local, provedor, estado, código de erro, duração, identificador remoto e custo quando informado. Não registram perguntas, tela, chave ou corpo bruto de erros. O relatório solicitado continua sendo salvo no histórico, como nas outras sessões.

## Adicionar outro mecanismo

1. Implementar `WebSearchProvider` em `Mac/Sources/WebSearch`, declarando `info` com identificador, nome e entrada de credencial, e traduzindo a API para `WebSearchProviderResponse`.
2. Adicionar a entrada de credencial em `Keychain.Key` e registrar o adaptador em `WebResearch.service`. O menu usa esse registro automaticamente.
3. Mapear erros conhecidos para `WebSearchProviderError`. Não repassar mensagens brutas que possam conter dados privados.
4. Devolver `answer` com fontes ou somente fontes para o estado parcial. Preencher trechos, datas, limitações e custo apenas quando disponíveis.
5. Testar o adaptador com rede simulada e verificar o contrato. Não é necessário alterar a ferramenta, os adaptadores de conversa ou o iPhone.

## Verificação

Execute `swift test` para o contrato compartilhado, os dois envelopes de conversa, leitura legada, serviço e Exa com `URLProtocol` simulado. Os testes não usam chaves reais nem acessam a rede.

Recompile o Mac com `./scripts/build-mac.sh`, feche a versão antiga e abra `build/Bluey.app`. O arquivo `Shared/WebSearchResult.swift` já está incluído no projeto Xcode. Recompile e instale também o iPhone; `project.yml` inclui a pasta Shared para futuras regenerações.

Validação manual pendente:

1. Com a pesquisa desativada, solicitar uma busca e conferir a explicação sem promessa prévia de pesquisa.
2. Selecionar Exa e cancelar sem cadastrar chave: conferir seleção e mensagem de configuração.
3. Salvar chave, reiniciar o Mac e conferir persistência; testar substituição, Save vazio, Cancel e Remove Key. Trocar a pesquisa durante uma conversa não deve reconectar o cérebro.
4. Com chave válida, pesquisar presidente atual, notícia recente de IA e uma pergunta em português com restrições explícitas. Conferir resposta, idioma, fontes, tempo e consumo no painel Exa.
5. Repetir com os dois cérebros, conferir o relatório no Mac e histórico no iPhone; verificar também sessões antigas.
6. Conferir mensagens de chave recusada, créditos, limite e ausência de rede conforme viabilidade, sem consumir cota desnecessariamente.

O build do iPhone e os testes no aparelho serão feitos pelo usuário. O teste real com Exa depende da chave cadastrada pelo menu. Agendamento e APIs específicas de tarifas de viagem ficam fora desta implementação. Pesquisa web não garante inventário ou preços de viagem em tempo real.
