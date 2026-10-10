## v0.6.0 (2026-10-10)

### Feat

- clima no horário do próprio lugar (fuso pelo Open-Meteo quando há coordenadas salvas; antes o "Now" e o dia/noite usavam o relógio da máquina) e nome/fuso presos ao relatório a que pertencem durante a troca de lugar; card de clima com "Updated 9:02", aviso de offline com Refresh após 1 h (sem alerta de chuva velho e sem dias passados) e nome do lugar clicável para trocar; microfone mutado mantém um card discreto com Unmute enquanto o app segura o mic (antes o card sumia sem volta); com o popup aberto só alertas trocam o card, novidades piscam no ponto; "Clear all" dos lembretes pede um segundo clique; pílula com opção de largura ajustada ao texto; dicas nos itens da aba Activities; card de carga some a 100%; status do IPC com fuso e idade do clima
- local do clima escolhido nas opções (aba Weather): busca por cidade com sugestões do geocoding do Open-Meteo (↑/↓ e Enter ou clique) e "Use automatic location" para voltar ao palpite pelo IP; grava no mesmo local do Omarchy (omarchy-weather-location), compartilhado com o painel de clima dele; o wttr.in passa a ser consultado pelas coordenadas salvas em vez do nome (cidade homônima não cai em outro lugar), o card mostra o nome salvo, e o arquivo é relido a cada 30 s e ao abrir o popup (o watch não vê o arquivo ser criado nem voltar depois do --clear)
- melhorias de UX no popup: iniciar timer, cronômetro ou Pomodoro com outro em andamento pede confirmação (a mesma tecla de novo substitui, Esc mantém); atividades escondidas voltam com "Show N hidden" ou u; fim do timer toca som (não com Não perturbe) e "Time's up" fica até o OK (ou 1/5/30 min); scroll do volume proporcional (touchpad não pula mais de 0 a 100%); campo de timer mostra "12 min · ends at 14:42" ou como escrever; sleep timer com duração configurável; Quick toggles que abrem outra tela marcados com ↗; ações do card Modes como "Turn off DND"; ordem do carrossel fixa com o popup aberto; tooltips nos pontos; prévia do tempo ao passar o mouse na barra; ↑/↓ volume e [ ] 10 s no card de mídia; Power saver na bateria baixa; ícone de mídia pausada esmaecido; Reset pede confirmação; aba Quick vira Popup; texto secundário com opacidade em vez de Qt.darker; previews atualizados
- card de updates também checa plugins e temas instalados via git (git ls-remote, sem escrever nada nem pedir senha, com os mesmos critérios do omarchy plugin/theme update), mostra os commits no card e o botão Update roda omarchy plugin update e omarchy theme update quando há algo; o terminal do Update deixa uma marca ao terminar para o card ser rechecado na hora

## v0.5.0 (2026-10-09)

### Feat

- timers com anel de progresso, pílula pulsando nos últimos 10 s e card "Time's up" (Repetir / +1 min / OK); Pomodoro conta os blocos do dia e pode ligar o Não perturbe no foco; campo de timer livre no Quick start; lembretes com +5 min e card para adiar quando tocam; card da gravação salva com miniatura (Play / Copy / Folder) e ponto vermelho durante a gravação; fones Bluetooth com "Use for audio" e aviso de bateria baixa de periféricos; alerta de chuva como atividade
- troca de faixa animada de verdade: título antigo sai antes do novo entrar (no sentido da troca), capa e fundo desfocado em crossfade sem piscar nem afundar, cor da capa misturada em OKLab (sem cinza nem arco-íris), barra de progresso deslizando contínua entre os segundos (no card e na pílula) e texto da pílula deslizando na troca
- card de mídia como player de verdade: controles redondos centralizados (shuffle, −10 s, anterior, play/pause em destaque, próxima, +10 s, repeat, só o que o player suporta), capa desfocada ao fundo, tempo decorrido e restante dos lados da barra, álbum no cabeçalho, capa que abre o player, troca de faixa animada e mini equalizador na pílula; player pausado cede a pílula após um tempo (5 min, 15 min, 1 h ou nunca) e players podem ser escondidos do Now Bar sem perder as teclas de mídia
- módulo Updates: checa de tempos em tempos (intervalos prontos ou qualquer valor de 5 min a 7 dias, e uma vez após ligar o PC) as atualizações do Omarchy, pacotes oficiais, AUR e Flatpak (só as fontes que a máquina tem: Flatpak apenas se instalado), num card de prioridade normal que assume a pílula quando acha novidade, com botão Update (omarchy-update e flatpak update num terminal, que pedem a senha lá) e nova checagem sozinha após atualizar
- carregamento em azul e verde: a pílula se enche até a carga com gradiente azul→verde e uma onda de luz passando, e o popup ganha borda em gradiente, fundo azul-esverdeado e barra com a mesma onda, em qualquer porcentagem
- animações no Now Bar: o popup se desdobra a partir da pílula com as seções entrando em cascata, cards deslizam do lado da troca com a altura acompanhando, opções entram deslizando, e a pílula afunda ao clicar, dá um salto quando uma atividade assume sozinha e pulsa em vermelho no que é urgente; opção Animations (Look → Motion) desliga tudo

### Fix

- ações que abrem um app (Update, Edit e Open do screenshot) fecham o popup antes, para o terminal/editor receber o teclado; antes o popup ficava aberto por cima e podia travar aberto enquanto o diálogo de senha do Flatpak estava na tela
- atividade que fica mais importante (mídia pausada que volta a tocar, lembrete chegando) pega o foco como uma nova; antes só um id inédito pegava

## v0.4.1 (2026-10-06)

### Fix

- **security**: download de capa resolve o nome uma vez, recusa endereços locais (loopback, LAN, link-local, CGNAT, multicast) e conecta só ao endereço conferido, e players tocando viram no máximo 6 cards
- capas em PNG de 16 bits por canal ficavam sem cores dinâmicas (histograma com 16 dígitos hex não era reconhecido); extração pede saída de 8 bits e o modelo aceita os dois formatos

## v0.4.0 (2026-10-06)

### Feat

- aba Quick nas opções para configurar Quick toggles (mostrar, quais botões e trocar os indicadores do Omarchy) e Quick start (mostrar, timers, extras e Pomodoro); popup mostra só os itens escolhidos

### Fix

- **security**: aviso de câmera/microfone não pode ser escondido por IPC, gravação só conta a do próprio usuário, screenshots ignoram links simbólicos, título gigante de mídia é cortado antes de ser tratado, título do nowbar-run não vira opção da notificação, decodificador da capa fixado pelos bytes e Restore do clima preserva bindings.lua simbólico

## v0.3.0 (2026-10-06)

### Feat

- popup fica vermelho (borda e fundo) em atividades urgentes como a pílula: câmera/microfone em uso, gravação de tela, bateria baixa e script com erro

## v0.2.0 (2026-10-06)

### Feat

- Quick toggles no popup com tudo o que os indicadores do Omarchy fazem (DND, night light, stay awake, gravação, lembrete, ditado), comando nowbar quick e botão para trocar o widget de indicadores (lembra a posição na barra, Restore devolve; com ele desligado o Now Bar responde ao omarchy.indicators refresh)
- opções do Now Bar em abas (Activities, Look, Timers, Weather) com Tab para alternar, bloco reutilizável para trocar widgets do Omarchy e comando nowbar settings [aba]
- botão para trocar o widget de clima do Omarchy pelo Now Bar (desativa omarchy.weather e aponta SUPER+CTRL+ALT+W para o card num bloco marcado do bindings.lua, com backup) e Restore para desfazer
- card de clima no Now Bar (substitui o widget de clima): temperatura, sensação, vento, umidade, chuva, nascer/pôr do sol, próximas horas e 3 dias com barra de faixa, cores do céu, unidade automática ou escolhida, comando nowbar weather; conta na posição da pílula sem tomar o lugar de atividades ao vivo
- Now Bar vira clone de omarchy.media e assume o IPC media das teclas de mídia (playPause, next, previous, play, pause, troca de fonte, status) com OSD, e lembretes aparecem na hora via inotify nos timers do systemd
- popup de mídia ganha as cores da capa: borda na cor de destaque e fundo com um tom da cor predominante (ajustado ao tema para manter a leitura), com transição ao trocar de card
- nowbar-run roda um comando e o mostra na pílula com tempo decorrido, depois sucesso ou falha e notificação
- popup com barra de progresso arrastável, volume, miniatura do screenshot, Now Brief na pílula vazia, Pomodoro e Sleep no início rápido, e opções de módulos, presets e durações do Pomodoro
- serviço lê cada player MPRIS (pausado continua com card), Pomodoro e timer de sono persistentes com notificação, VPN via nmcli/tailscale, Bluetooth, pasta de screenshots via inotify, clima e atualizações para o Now Brief, e IPC timer por horário, pomodoro e sleep
- modelo ganha um card por player (com dados de seek e volume), Pomodoro, timer de sono, timer por horário e presets configuráveis, VPN nos modos, bateria baixa, Bluetooth conectado, screenshot recém-salvo, Now Brief e push com tempo decorrido e estado, com testes
- mídia usa a cor da capa na pílula, progresso, pontinhos, fundo da capa e botão principal, com a opção Cover colors para desligar
- serviço extrai a cor de destaque da capa já validada (ImageMagick com limites e timeout, descartada ao trocar de faixa) e a expõe em coverAccent no status do IPC
- escolha da cor de destaque a partir do histograma da capa (cor mais viva com área relevante, ajustada para ficar legível; capa preta/branca/cinza mantém a do tema) e preferência coverAccent, com testes

### Fix

- troca do widget de clima lembra a posição na barra para o Restore, e os status não decidem nada enquanto o shell ainda não responde (tentam de novo)

## v0.1.0 (2026-10-05)

### Feat

- Now Bar: pílula na barra com a atividade ao vivo mais importante (mídia com capa do álbum, timer, cronômetro, lembretes, gravação de tela, ditado, câmera/microfone em uso, modos, carregamento e atualizações enviadas por scripts), scroll para alternar, popup em carrossel com detalhes e ações, e IPC `nowbar`
