# Transcrição centralizada

## Responsabilidades

`SpeechSession` é o único dono do microfone, da gravação AAC, dos sons do personagem e da linha de tempo das perguntas. Não conhece OpenAI, Gemini, chaves ou sockets. A escuta pode começar e continuar sem conexão com um provedor ou com o Mac.

`LocalSpeechRecognition` usa exclusivamente `SpeechAnalyzer`/`SpeechTranscriber`. Resolve o idioma, instala os recursos locais, converte áudio fora do callback do microfone e publica texto final com intervalos de tempo. A recuperação de arquivos usa a mesma configuração de modelo e a mesma transformação de resultados. Não existe outro backend de reconhecimento.

`SpeechTranscript` classifica a fala pelos horários do áudio, sem depender de quando o resultado chega. Um trecho pertence à pergunta pelo ponto médio de seu intervalo. Os resultados indexados em palavras permitem dividir frases que atravessam a fronteira do gesto. O histórico completo é persistido no `SessionStore`; o contexto em memória retém os últimos dez minutos, e cada pergunta leva no máximo 6.000 caracteres de contexto novo.

`LiveVoice` coordena a conexão e serializa perguntas. Só recebe `TextQuestion` da camada de fala e delega o protocolo do provedor a um `TextConversationAdapter`. Não captura, converte, envia ou transcreve áudio. Mantém até oito perguntas aguardando o provedor e não repete automaticamente um pedido cuja execução ficou incerta após uma queda.

`NotesSync` sincroniza o texto canônico e arquiva gravações em operações independentes. `MeetingNotes` no Mac grava arquivos e nunca chama uma API de reconhecimento. O comando de arquivamento é `archiveAudio`; o antigo comando de transcrição foi removido.

## Delimitação e finalização

O gesto registra suas fronteiras antes de esperar operações assíncronas. O texto é classificado pelo tempo original, inclusive se chegar depois de a pergunta terminar. Ao soltar a tela, a fila serial fecha a sequência de áudio atual e direciona os próximos buffers a uma nova sequência limitada. A captura do microfone e a gravação continuam.

O app espera a análise consumir a sequência fechada, chama `finalizeAndFinishThroughEndOfInput()` e aguarda o leitor consumir todos os resultados até o encerramento do stream. Só então consolida a pergunta. Não espera que `resultsFinalizationTime` alcance o fim do silêncio: esse marcador não é uma confirmação de consumo de toda a entrada. A espera anterior de três segundos podia rejeitar perguntas já transcritas e foi removida.

Depois da drenagem, um novo analisador Apple consome o áudio acumulado, com os horários convertidos para a linha de tempo contínua da sessão. Os analisadores trabalham em sequência e usam retenção temporária do modelo (`lingering`). Não há download por pergunta. Perguntas consecutivas preservam a ordem; uma sequência sem áudio é encerrada sem esperar resultados inexistentes. Um gesto sem fala reconhecida não envia uma pergunta. O comportamento e a latência dessa troca precisam ser validados no aparelho.

O reconhecedor continua recebendo áudio entre perguntas. Ao encerrar a sessão, a captura para, as operações pendentes são esvaziadas, a análise finita é drenada e o último arquivo é registrado antes de o histórico ser fechado. Não há suporte configurado para gravação em segundo plano: ir para o background encerra a sessão.

## Provedores atuais e futuros

Todo provedor recebe o mesmo contrato `TextQuestion`: ID, pergunta consolidada e contexto. O contrato de entrada não inclui áudio. O adaptador publica eventos comuns de conexão pronta, texto, conclusão, ferramentas, interrupção, erro e retomada.

Para adicionar outro modelo:

1. Implementar `TextConversationAdapter`, incluindo codificação de perguntas/contexto/resultados de ferramentas e normalização dos eventos de saída.
2. Registrar o adaptador em `VoiceProvider.textConversation`.
3. Adicionar o modelo/configuração e a emissão de credenciais no Mac, e o transporte de conexão correspondente em `LiveVoice.connect`.
4. Acrescentar testes do protocolo ao conjunto `TextConversationTests`, incluindo a ausência de áudio do usuário e a regra de que contexto sozinho não dispara resposta.
5. Validar ferramentas e recuperação de conexão com o novo provedor. Não alterar `SpeechSession`, o reconhecedor ou o formato canônico para integrar o modelo.

OpenAI recebe `input_text` e só responde após `response.create`. Gemini recebe `clientContent`, com o fechamento do turno controlado pelo aplicativo. A retomada sem uma sessão do provedor usa contexto textual como conteúdo de usuário, sem promovê-lo a instrução de sistema.

O Gemini 3.8 Live ainda gera áudio de saída. O aplicativo o descarta e usa `outputTranscription` para o balão. Isso não é reconhecimento remoto do microfone nem fallback; o custo dessa saída não foi eliminado por esta mudança.

## Histórico e gravações

Os tipos persistidos em `Shared/SessionModels.swift` mantêm compatibilidade com as sessões antigas. Os novos trechos usam `source: apple`, IDs locais, intervalos de áudio e referências às perguntas. Uma pergunta que gerou vários resultados conta uma única vez. Não há atribuição fictícia de falantes; sessões antigas mantêm seus rótulos.

Gravações novas entram na fila de arquivamento. O arquivo no iPhone só é removido depois da confirmação do Mac e da persistência dessa confirmação. Envios de áudio para o Mac são limitados a dois simultâneos. A captura e a análise têm filas de buffers limitadas.

Pendências antigas sem `purpose` indicam reconhecimento ainda necessário. Uma falha do reconhecedor marca o arquivo corrente com `purpose: localRecovery`. A recuperação usa a Apple, um arquivo por vez, com a escuta ao vivo parada; iniciar uma sessão cancela e espera a recuperação anterior. O texto já consolidado da captura é preservado. Nenhuma recuperação gera perguntas ou executa ferramentas.

Arquivos ausentes ou incompatíveis continuam explicitamente pendentes, com mensagem no histórico. Não há solicitação a transcritores externos, nem mesmo após falha ou atualização do app. Trechos de áudio que já estejam apenas no arquivo do Mac não são baixados automaticamente para nova análise nesta versão.

## Compatibilidade e idioma

A interface do app mantém a implantação iOS 17. A entrada por voz exige iOS 26, aparelho compatível com `SpeechTranscriber` e um idioma suportado em execução. Não há fallback para `SFSpeechRecognizer`, outro serviço Apple ou serviço remoto. O seletor de idioma permite usar o idioma do dispositivo ou escolher português brasileiro e inglês; cada opção continua sujeita à verificação de suporte real.

## Validação

Verificações realizadas sem executar os provedores ou acessar o microfone:

- Análise sintática dos arquivos Swift do aplicativo e dos testes.
- A correção da finalização recebeu conferência estática adicional do reconhecedor contra o SDK iOS, sem executar o microfone.
- Validação dos arquivos do projeto Xcode e do Info.plist com `plutil`.
- Revisão dos pontos de captura, arquivamento, finalização, sincronização e recuperação.
- Auditoria do código para remover os modelos e endpoints antigos de transcrição e os eventos de áudio de entrada.

Uma compilação intermediária do Mac terminou com sucesso antes da última parte da integração. Ela não valida as alterações posteriores. A tentativa inicial de compilação do iPhone encontrou bloqueios de sandbox; a nova tentativa foi cancelada, e o usuário decidiu compilar no Xcode. Não foi executada nova compilação.

Após a correção da finalização, o usuário confirmou que o fluxo funcionou no teste manual. Essa confirmação valida a resolução do erro `The speech transcript is not ready`; os demais cenários abaixo continuam pendentes de validação específica.

Há 16 testes em `Tests/GooglySharedTests`, cobrindo perguntas consecutivas, resultados atrasados, gestos vazios, deduplicação, limites de contexto, protocolo textual dos dois provedores, ferramentas e compatibilidade de sessões antigas. Eles ainda não foram executados. Para executá-los após preparar o ambiente de compilação, use `swift test` na raiz.

No Xcode e no iPhone, validar pelo menos:

1. Instalação inicial do modelo e idioma selecionado; falha clara em aparelho/idioma incompatível.
2. Perguntas em português com nomes próprios, termos técnicos e pausas; soltura imediata após a última palavra.
3. Pausa silenciosa antes de soltar a tela; gestos totalmente silenciosos; perguntas rápidas e consecutivas; ausência de respostas à fala de fundo.
4. Perguntas simples e leitura/apontamento de tela nos dois provedores.
5. Queda de rede durante escuta, resposta e execução de ferramenta; nenhum pedido incerto repetido automaticamente.
6. Mac desconectado, sincronização posterior e confirmação do arquivamento antes de remover a cópia local.
7. Sessões antigas, gravações pendentes e recuperação local interrompida por uma nova sessão.
8. Encerramento durante fala, troca de rota de áudio e ida ao background.
9. Sessão longa para avaliar memória, bateria e estabilidade.

Os logs `Bluey:` registram início/fim do gesto, finalização local, envio de pergunta, primeira resposta e início de ferramentas sem registrar texto da conversa. Usar esses eventos para comparar latência; ainda não há medidas de precisão ou tempo no aparelho.
