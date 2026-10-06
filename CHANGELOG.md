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
