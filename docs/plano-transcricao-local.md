# Plano: transcrição local da Apple no Bluey

Status: núcleo implementado. Verificações estáticas concluídas; compilação final, testes automatizados e validação no iPhone ainda pendentes. A compilação no Xcode ficou com o usuário, conforme solicitado. Consulte `docs/local-speech.md` para a arquitetura e o roteiro de validação.

## Objetivo e requisitos

Usar o reconhecimento de fala da Apple no iPhone como fonte única do texto da sessão. Reutilizar esse texto nas notas e na entrada de OpenAI Realtime e Gemini Live.

- Não enviar áudio do microfone aos modelos Live.
- Remover as transcrições remotas de entrada e de gravações, inclusive seus fallbacks e retentativas. Nenhum erro local poderá ativar OpenAI Transcribe ou Gemini Transcribe.
- Transcrever durante toda a sessão acordada. Registrar a fala de fundo como contexto; responder apenas às perguntas feitas segurando a tela.
- Manter OpenAI e Gemini como provedores de conversa, com as ferramentas executadas no Mac.
- Manter histórico, notas, gravações existentes e alternância de provedor.
- Não pressupor paridade de qualidade ou um acréscimo fixo de latência. Medir no aparelho.

## Escopo definido

O reconhecimento usará `SpeechAnalyzer` e `SpeechTranscriber`, disponíveis a partir do iOS 26, com verificação de aparelho, idioma e modelos instalados. Não acrescentar um segundo reconhecedor como fallback nesta implementação.

Manter inicialmente a implantação geral do app em iOS 17 e proteger a função com disponibilidade de API. Em versões ou aparelhos incompatíveis, informar que a entrada por voz local está indisponível. Não desviar para reconhecimento remoto.

O texto da fala de fundo será armazenado localmente e poderá ser enviado como contexto antes da pergunta para os dois provedores. Isso amplia o contexto habitual do Gemini: hoje ele recebe apenas o áudio das perguntas. Não gerar respostas a partir desse contexto sozinho.

Preservar as gravações AAC como arquivo local e no Mac, separando o arquivamento de qualquer transcrição. Os arquivos de cinco minutos deixam de ser a unidade necessária para obter texto.

A saída do Gemini é um assunto separado: `gemini-3.8-live` responde em áudio, e o Bluey usa `outputTranscription` para escrever o balão. Esta implementação remove a transcrição remota da voz do usuário e das notas; mantém a transcrição da resposta do Gemini enquanto esse for o canal de saída. Ela não é fallback de entrada. Eliminar também essa saída exigiria alterar o provedor ou o contrato de resposta, e não faz parte deste plano.

Não incluir mudanças no comportamento de `Point Here`, personalidade, pesquisa web ou desenho do cursor.

## Fluxo atual que será substituído

| Componente | Comportamento atual | Destino |
| --- | --- | --- |
| `LiveVoice.startAudio` / `sendMic` | Captura, converte e envia áudio ao provedor | Capturar uma vez e alimentar o reconhecedor local |
| OpenAI Realtime | Recebe áudio contínuo; `gpt-4o-mini-transcribe` fornece texto ao app | Receber mensagens de texto; remover configuração e eventos de transcrição de entrada |
| Gemini Live | Recebe áudio durante o gesto; `inputTranscription` fornece a pergunta | Receber pergunta e contexto em texto; remover atividade de áudio e transcrição de entrada |
| `ChunkRecorder` | Grava toda a sessão em AAC de cinco minutos | Continuar arquivando, sem disparar transcrição remota |
| `NotesSync.upload` | Envia gravações para `transcribe` e repete em caso de falha | Arquivar áudio e sincronizar texto por operações independentes |
| `MeetingNotes` | Chama transcritores e escreve arquivos de notas | Receber texto local e arquivar áudio; remover clientes de transcrição |
| `SessionStore` | Concilia texto preliminar do Live e texto posterior dos arquivos | Armazenar um texto canônico local, preservando leitura das sessões antigas |

O modelo Live atualmente entende áudio diretamente. Os eventos de transcrição de entrada alimentam o histórico, mas não são uma etapa que o Live necessariamente espera antes de responder.

## Etapas de implementação

### 1. Registrar a referência atual e preparar a validação

- [ ] Registrar versões, aparelho, idioma e provedor usados nas medições.
- [ ] Separar amostras consentidas já disponíveis ou gravações locais novas: português, nomes próprios, termos técnicos, fala com pausas e fala de fundo. Não executar transcrição remota de amostras para produzir a referência.
- [ ] Quando disponíveis, usar transcrições e tempos já obtidos no fluxo atual para comparação. Se não existirem, registrar essa limitação, sem apresentar estimativas como medições.
- [x] Definir eventos de tempo: início/fim do gesto, último áudio da pergunta, texto consolidado, envio ao modelo, primeira resposta, início da ferramenta e resposta concluída.
- [x] Usar logs de estado e duração sem incluir áudio, chaves ou texto integral da conversa.

Aceite: há casos reproduzíveis e uma forma de medir o caminho local e cada provedor, sem criar nova dependência dos transcritores que serão removidos.

### 2. Implementar o serviço local de reconhecimento

- [x] Criar um componente dedicado, por exemplo `LocalSpeechRecognition`, independente de OpenAI, Gemini e da conexão com o Mac.
- [ ] Representar estados de preparação, download, escuta, finalização e falha. A preparação deve acontecer antes de indicar que a escuta está pronta.
- [x] Verificar `SpeechTranscriber.isAvailable` e resolver o idioma por `supportedLocale(equivalentTo:)`; não presumir suporte apenas pela versão do sistema.
- [x] Usar `AssetInventory` para verificar, instalar e acompanhar os modelos necessários. Não iniciar perguntas enquanto os recursos essenciais estiverem indisponíveis.
- [x] Reutilizar a permissão de microfone. Não adicionar o fluxo de autorização do antigo `SFSpeechRecognizer` ao usar apenas `SpeechAnalyzer`.
- [x] Alimentar o reconhecedor pelo mesmo ponto de captura usado para gravar áudio. Copiar buffers quando necessário e processar conversão/análise fora do callback de áudio.
- [x] Negociar formato com `bestAvailableAudioFormat`; não reutilizar obrigatoriamente as frequências específicas dos provedores. APIs auxiliares disponíveis apenas no iOS 27 não podem se tornar requisito acidental do caminho iOS 26.
- [x] Manter uma linha de tempo baseada em amostras de áudio, com origem na sessão, e IDs próprios da sessão. Não usar o horário de chegada do callback como horário da fala.
- [x] Começar com resultados finais como fonte persistida. Se resultados provisórios forem habilitados, substituí-los por intervalo e acompanhar `resultsFinalizationTime`, sem concatenar hipóteses ou depender de sua reemissão com `isFinal`.
- [x] Encerrar e drenar a análise antes de fechar o histórico. Descartar callbacks de instâncias antigas sem perder o vínculo com a sessão correta.

Aceite: o iPhone produz texto local com horários durante uma sessão, independentemente do provedor, sem enviar áudio a serviços de transcrição.

### 3. Separar escuta, pergunta e conexão

- [x] Desacoplar a captura local da obtenção de token e da conexão Live. A queda do provedor não deve encerrar a transcrição local.
- [x] Criar um ID de pergunta ao iniciar o gesto e marcar início e fim na linha do áudio.
- [x] Consolidar a fronteira no início da pergunta e usar os intervalos de tempo para impedir que a fala de fundo anterior seja classificada como pergunta. Prever resultados que atravessam essa fronteira.
- [x] Ao soltar, fechar a sequência correspondente, mantendo o microfone ativo e os próximos buffers em uma nova fila limitada; finalizar o analisador anterior e iniciar o seguinte em ordem.
- [x] Esperar o consumidor incorporar todos os resultados até o fim do stream. Não usar o horário da última fala como confirmação do fim do áudio, que pode incluir silêncio.
- [x] Enviar somente a pergunta consolidada, com o contexto novo pertinente. Não disparar respostas por resultado parcial ou por fala de fundo.
- [x] Limitar o contexto enviado por tamanho e recência, mantendo a transcrição integral no armazenamento local. Não reenviar todo o histórico a cada trecho nem adicionar outra chamada de modelo apenas para resumir nesta etapa.
- [x] Tratar gesto sem fala, fala durante preparação e perguntas consecutivas. Não enviar pergunta vazia ou texto provisório como comando de ferramenta.
- [x] Definir uma fila/serialização explícita para perguntas e respostas em andamento, incluindo cancelamento. Uma finalização antiga não pode disparar uma pergunta nova por engano.

Aceite: cada gesto válido produz uma pergunta completa; as últimas palavras são preservadas e a fala posterior não entra nessa pergunta.

### 4. Conectar a entrada textual à OpenAI

- [x] Remover envio de `input_audio_buffer.append`, commits de áudio e configuração de transcrição de entrada desse caminho.
- [x] Remover VAD e tratamento de transcrição de entrada que deixarem de ser necessários.
- [x] Adicionar contexto e pergunta usando `conversation.item.create` com `input_text`.
- [x] Enviar `response.create` somente depois de a pergunta estar consolidada e os itens terem sido enviados em ordem.
- [x] Preservar respostas textuais, screenshots, chamadas de ferramenta e seus resultados.
- [x] Atualizar as instruções para reconhecer texto de fundo como contexto e a pergunta marcada como solicitação ativa.
- [x] Reconstruir o contexto de uma nova conexão a partir do histórico local, sem reenviar perguntas como pedidos de execução.

Aceite: perguntas e ferramentas funcionam com OpenAI sem áudio de entrada e sem transcrição remota.

### 5. Conectar a entrada textual ao Gemini

- [x] Remover `inputAudioTranscription`, envio de áudio, preroll e `activityStart`/`activityEnd` do caminho de perguntas.
- [x] Usar `clientContent` para contexto e pergunta, com `turnComplete` controlado explicitamente. Não tratar cada trecho de fundo como turno concluído.
- [x] Coordenar o envio com respostas e ferramentas em andamento, considerando a semântica de interrupção do Gemini.
- [x] Atualizar as instruções que atualmente afirmam que o Gemini só recebe o que foi dito durante o gesto.
- [x] Preservar ferramentas, screenshots, retomada de sessão, resposta no balão e o tratamento atual da saída de áudio/transcrição da resposta.
- [x] Restaurar contexto em uma sessão nova como conteúdo de conversa, sem promover a transcrição do usuário a instrução de sistema.
- [x] Controlar o que já foi enviado em cada conexão. Retomada válida de sessão e sessão nova exigem estratégias distintas para evitar duplicação.

Aceite: perguntas e contexto funcionam no Gemini sem áudio do usuário ou chamadas a Gemini Transcribe; o balão continua funcionando.

### 6. Unificar o histórico e a sincronização de notas

- [x] Representar cada trecho local com ID estável, ID da sessão e intervalo de áudio. Vincular perguntas aos trechos correspondentes sem criar duas versões concorrentes da transcrição.
- [x] Preservar leitura de `sessions.json` antigo e os textos/speakers existentes. Novos campos devem ter migração compatível.
- [x] Remover a necessidade de esconder texto local esperando uma transcrição posterior. Revisar `displayEntries`, exportação e `recentText`.
- [x] Salvar texto continuamente com agrupamento limitado no tempo. Uma fala contínua não pode adiar indefinidamente a persistência ou sincronização.
- [x] Sincronizar notas com IDs estáveis, preservando ordem, horários, perguntas, respostas e relatórios.
- [x] Manter `notes.md` e `session.json` no Mac com o formato legível esperado, adaptando referências à transcrição posterior e ao estado de pendência.
- [x] Separar o envio/arquivamento de AAC do envio de texto, preservando o arquivo antes de remover sua cópia no iPhone.
- [x] Não inventar rótulos A/B nas sessões novas: o `SpeechTranscriber` inspecionado não oferece identificação de falantes equivalente à atual. Exibir texto sem atribuição de pessoa quando ela não for conhecida.

Aceite: o mesmo texto local aparece no histórico do iPhone e nas notas do Mac; gravações continuam disponíveis; sessões antigas abrem normalmente.

### 7. Remover os caminhos remotos e tratar pendências

- [x] Remover os modelos `gpt-4o-mini-transcribe`, `gpt-4o-transcribe-diarize`, `gpt-transcribe` e `gemini-3.5-transcribe` dos caminhos de transcrição da aplicação.
- [x] Remover clientes de upload para endpoints de transcrição e o fallback diarizado → simples.
- [x] Remover o comando de rede `transcribe` e suas retentativas. Usar um comando separado de arquivamento de áudio, caso necessário.
- [x] Impedir que `retryPending` antigo continue enviando gravações automaticamente após a atualização.
- [x] Preservar arquivos e pendências antigas de forma explícita. Quando recuperáveis, processá-las com o reconhecedor Apple local, em fila limitada; quando não recuperáveis, registrar a situação sem fingir que foram transcritas.
- [x] Distinguir erros de reconhecimento, arquivamento e sincronização; falhar em uma operação não pode ativar outra nem excluir arquivos não confirmados.
- [x] Atualizar textos da interface e README para refletir transcrição local e ausência de processamento remoto posterior.

Aceite: nenhum caminho de erro, reconexão ou migração consegue chamar os transcritores remotos removidos.

### 8. Robustez e validação final

- [x] Recuperar falhas do analisador recriando o serviço local e, quando possível, reprocessando apenas áudio local ainda não consolidado. Não criar duplicatas na recuperação.
- [x] Tratar interrupção de áudio, troca de rota, ida ao segundo plano e retorno ao app. Não prometer escuta em segundo plano sem configuração e validação específicas.
- [x] Limitar filas de áudio/texto e recursos em sessões longas. Não acumular buffers de toda a sessão em memória.
- [x] Ao terminar a sessão, finalizar resultados, persistir, fechar gravação e encerrar conexões em ordem.
- [x] Em falha ou incompatibilidade local, mostrar indisponibilidade/erro. Nunca selecionar silenciosamente um reconhecedor remoto.
- [x] Adicionar testes relevantes para delimitação temporal de perguntas, finalização assíncrona, deduplicação, migração de sessões e recuperação de conexão sem reexecutar ferramentas.
- [ ] Validar os eventos enviados por cada adaptador: texto para perguntas, nenhum áudio do usuário, nenhuma configuração de transcrição de entrada e nenhum upload a transcritores.
- [ ] Compilar iPhone e Mac e executar a matriz abaixo. Validar também a disponibilidade do caminho iOS 26, sem depender apenas do SDK mais recente instalado.
- [ ] Medir latência e qualidade no aparelho. Comparar medianas e caudas quando houver amostras suficientes, separando tempo local, modelo e ferramentas.

Aceite: os requisitos do início deste documento são verificados e as limitações observadas estão registradas.

## Matriz mínima de validação

| Caso | Resultado esperado |
| --- | --- |
| Pergunta simples, OpenAI e Gemini | Resposta correta usando entrada textual |
| Leitura de tela e apontamento | Ferramentas continuam executando no Mac |
| Fala fora do gesto | Texto salvo; nenhuma resposta automática |
| Pergunta sobre conversa anterior | Contexto textual disponível aos dois provedores |
| Soltar a tela imediatamente após a última palavra | Palavra final preservada |
| Perguntas consecutivas e pausas no meio da frase | Fronteiras e IDs corretos; sem duplicação |
| Gesto vazio | Nenhuma pergunta vazia enviada |
| Download inicial ou idioma/aparelho incompatível | Estado claro; nenhum fallback remoto |
| Queda do Live durante fala | Texto local continua; retomada sem reexecutar ações |
| Mac desconectado | Histórico local preservado; sincronização posterior |
| Encerrar durante fala ou processamento | Resultados anteriores ao encerramento preservados |
| Sessão longa, interrupção ou troca de microfone | Recursos limitados e recuperação explícita |
| Abrir sessões antigas e atualizar com arquivos pendentes | Dados preservados; nenhum envio aos transcritores antigos |
| Inspeção dos pedidos de rede | Sem áudio do usuário para Live ou transcritores; arquivamento restrito ao Mac |

## Fontes e ressalvas

- [Apple: SpeechAnalyzer e o modelo local](https://developer.apple.com/videos/play/wwdc2025/277/).
- [Apple: instalação dos modelos com AssetInventory](https://developer.apple.com/documentation/speech/assetinventory?changes=_5).
- [Apple: finalizar um trecho sem encerrar a análise](https://developer.apple.com/documentation/speech/speechanalyzer/finalize%28through%3A%29?changes=_3).
- [Apple: resultados provisórios e finalização](https://developer.apple.com/documentation/speech/speechmoduleresult/resultsfinalizationtime).
- [Apple: autorização do reconhecedor antigo e distinção do processamento local](https://developer.apple.com/documentation/Speech/asking-permission-to-use-speech-recognition).
- [OpenAI: entrada textual e ferramentas em Realtime](https://developers.openai.com/api/docs/guides/realtime-conversations).
- [Gemini: conteúdo incremental e controle dos turnos](https://ai.google.dev/gemini-api/docs/live-api/capabilities).
- [Gemini 3.8 Live: modalidade de saída](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live).

As APIs e o SDK foram inspecionados; suporte efetivo ao idioma/aparelho, precisão, estabilidade e latência ainda precisam ser verificados no iPhone. O plano não assume equivalência de identificação de falantes nem eliminação do custo da saída de áudio do Gemini.
