import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Idioma do app (Ajustes). Cobre Ajustes + mesa Jogar;
/// demais telas seguem em PT-BR até a migração completa.
enum AppLang { pt, en, es, zh }

class AppLocale {
  static const _key = 'app_lang';
  static final ValueNotifier<AppLang> current =
      ValueNotifier<AppLang>(AppLang.pt);

  static String get code => current.value.name;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = (prefs.getString(_key) ?? 'pt').trim().toLowerCase();
      current.value = AppLang.values.asNameMap()[raw] ?? AppLang.pt;
    } catch (_) {}
  }

  static Future<void> set(AppLang lang) async {
    current.value = lang;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, lang.name);
    } catch (_) {}
  }

  static const languageNames = {
    AppLang.pt: 'Português (BR)',
    AppLang.en: 'English',
    AppLang.es: 'Español',
    AppLang.zh: '中文 (简体)',
  };

  /// Idioma do Scryfall correspondente (para a busca de arte).
  static String get scryfallLang => switch (current.value) {
        AppLang.pt => 'pt',
        AppLang.en => 'en',
        AppLang.es => 'es',
        AppLang.zh => 'zhs',
      };

  static String t(String key) => _v[key]?[code] ?? _v[key]?['pt'] ?? key;

  // pt / en / es / zh
  static const _v = <String, Map<String, String>>{
    // ---------- Ajustes ----------
    'settings_title': {
      'pt': 'Ajustes',
      'en': 'Settings',
      'es': 'Ajustes',
      'zh': '设置'
    },
    'settings_currency': {
      'pt': 'Moeda',
      'en': 'Currency',
      'es': 'Moneda',
      'zh': '货币'
    },
    'settings_pricing': {
      'pt': 'Referência de preço',
      'en': 'Price reference',
      'es': 'Referencia de precio',
      'zh': '价格参考'
    },
    'settings_pricing_hint': {
      'pt':
          '“Inglês (Imprint)” usa o preço da versão em inglês sem alterar sua carta.',
      'en': '"English (Imprint)" uses the English version price.',
      'es': '“Inglés (Imprint)” usa el precio de la versión en inglés.',
      'zh': '“英文（Imprint）”使用英文版本的价格。'
    },
    'settings_update_quote': {
      'pt': 'Atualizar cotação agora',
      'en': 'Refresh rate now',
      'es': 'Actualizar cotización ahora',
      'zh': '立即更新汇率'
    },
    'settings_quote_updated': {
      'pt': 'Cotação atualizada',
      'en': 'Rate updated',
      'es': 'Cotización actualizada',
      'zh': '汇率已更新'
    },
    'settings_table': {
      'pt': 'Mesa de jogo',
      'en': 'Game table',
      'es': 'Mesa de juego',
      'zh': '游戏桌面'
    },
    'settings_hide_names': {
      'pt': 'Sempre ocultar nomes das fichas',
      'en': 'Always hide token names',
      'es': 'Ocultar siempre los nombres',
      'zh': '始终隐藏衍生物名称'
    },
    'settings_hide_names_sub': {
      'pt': 'Deixa a arte limpa em todas as fichas da mesa.',
      'en': 'Keeps the art clean on every token.',
      'es': 'Mantiene el arte limpio en todas las fichas.',
      'zh': '让所有衍生物只显示插画。'
    },
    'settings_rotate': {
      'pt': 'Virar a carta de verdade (90°)',
      'en': 'Really rotate tapped cards (90°)',
      'es': 'Girar la carta de verdad (90°)',
      'zh': '横置时真正旋转牌（90°）'
    },
    'settings_rotate_sub': {
      'pt': 'Desligado mostra só o selo VIRADA.',
      'en': 'Off shows only the TAPPED badge.',
      'es': 'Apagado muestra solo el sello GIRADA.',
      'zh': '关闭则只显示横置标记。'
    },
    'settings_stack': {
      'pt': 'Máximo de cartas empilhadas',
      'en': 'Max stacked cards',
      'es': 'Máximo de cartas apiladas',
      'zh': '最大堆叠牌数'
    },
    'settings_stack_sub': {
      'pt': 'Quantas cópias aparecem atrás da principal.',
      'en': 'How many copies show behind the front card.',
      'es': 'Cuántas copias se ven detrás de la principal.',
      'zh': '主页牌后方显示几张。'
    },
    'fmt_title': {
      'pt': 'Formato da mesa',
      'en': 'Table layout',
      'es': 'Formato de mesa',
      'zh': '牌桌布局'
    },
    'tb_functions': {
      'pt': 'Funções da mesa',
      'en': 'Table actions',
      'es': 'Acciones de mesa',
      'zh': '牌桌操作'
    },
    'settings_display': {
      'pt': 'Exibição das cartas',
      'en': 'Card display',
      'es': 'Visualización de cartas',
      'zh': '卡牌显示'
    },
    'settings_display_sub': {
      'pt': 'O que aparece em cada carta no modo grade.',
      'en': 'What shows on each card in grid view.',
      'es': 'Qué se muestra en cada carta en vista de cuadrícula.',
      'zh': '网格视图中每张牌显示的内容。'
    },
    'settings_show_name': {
      'pt': 'Mostrar nome da carta',
      'en': 'Show card name',
      'es': 'Mostrar nombre de la carta',
      'zh': '显示牌名'
    },
    'settings_show_name_sub': {
      'pt': 'Desligado deixa só a arte (mais cartas visíveis).',
      'en': 'Off leaves just the art (more visible cards).',
      'es': 'Apagado deja solo el arte (más cartas visibles).',
      'zh': '关闭则只显示插画（显示更多牌）。'
    },
    'settings_show_set': {
      'pt': 'Mostrar edição',
      'en': 'Show set',
      'es': 'Mostrar edición',
      'zh': '显示系列'
    },
    'settings_show_set_sub': {
      'pt': 'Nome da edição abaixo do nome no modo grade.',
      'en': 'Set name below the name in grid view.',
      'es': 'Nombre de la edición debajo del nombre.',
      'zh': '网格视图中名称下方的系列。'
    },
    'settings_show_price': {
      'pt': 'Mostrar preço',
      'en': 'Show price',
      'es': 'Mostrar precio',
      'zh': '显示价格'
    },
    'settings_show_price_sub': {
      'pt': 'Valor em USD abaixo do nome no modo grade.',
      'en': 'USD value below the name in grid view.',
      'es': 'Valor en USD debajo del nombre.',
      'zh': '网格视图中名称下方的美元价格。'
    },
    'tap_title': {
      'pt': 'Virar fichas',
      'en': 'Tap tokens',
      'es': 'Girar fichas',
      'zh': '横置衍生物'
    },
    'tap_to_tap': {
      'pt': 'Virar ({n})',
      'en': 'Tap ({n})',
      'es': 'Girar ({n})',
      'zh': '横置（{n}）'
    },
    'tap_to_untap': {
      'pt': 'Desvirar ({n})',
      'en': 'Untap ({n})',
      'es': 'Enderezar ({n})',
      'zh': '重置（{n}）'
    },
    'tap_all': {
      'pt': 'Todas ({n})',
      'en': 'All ({n})',
      'es': 'Todas ({n})',
      'zh': '全部（{n}）'
    },
    'settings_language': {
      'pt': 'Idioma do app',
      'en': 'App language',
      'es': 'Idioma de la app',
      'zh': '应用语言'
    },
    'settings_language_sub': {
      'pt': 'Vale para Ajustes e mesa Jogar.',
      'en': 'Applies to Settings and the Play table.',
      'es': 'Vale para Ajustes y la mesa Jugar.',
      'zh': '适用于设置和游戏桌面。'
    },
    'common_cancel': {
      'pt': 'Cancelar',
      'en': 'Cancel',
      'es': 'Cancelar',
      'zh': '取消'
    },
    'common_save': {'pt': 'Salvar', 'en': 'Save', 'es': 'Guardar', 'zh': '保存'},
    'common_add': {'pt': 'Adicionar', 'en': 'Add', 'es': 'Añadir', 'zh': '添加'},
    'common_apply': {
      'pt': 'Aplicar',
      'en': 'Apply',
      'es': 'Aplicar',
      'zh': '应用'
    },
    'common_retry': {
      'pt': 'Tentar de novo',
      'en': 'Retry',
      'es': 'Reintentar',
      'zh': '重试'
    },
    'common_leave': {'pt': 'Sair', 'en': 'Leave', 'es': 'Salir', 'zh': '离开'},
    'play_exit_title': {
      'pt': 'Sair da mesa?',
      'en': 'Leave the table?',
      'es': '¿Salir de la mesa?',
      'zh': '离开牌桌？'
    },
    'play_exit_room_body': {
      'pt': 'Você sairá da sala {c} e a partida será encerrada neste aparelho.',
      'en': 'You will leave room {c} and the match will end on this device.',
      'es': 'Saldrás de la sala {c} y la partida terminará en este dispositivo.',
      'zh': '你将离开房间 {c}，本设备上的对局将结束。'
    },
    'play_exit_host_body': {
      'pt': 'A mesa será encerrada e os outros jogadores serão desconectados.',
      'en': 'The table will be closed and other players will be disconnected.',
      'es': 'La mesa se cerrará y los demás jugadores serán desconectados.',
      'zh': '牌桌将关闭，其他玩家将被断开连接。'
    },
    'play_exit_match_body': {
      'pt': 'A partida atual será encerrada neste aparelho.',
      'en': 'The current match will end on this device.',
      'es': 'La partida actual terminará en este dispositivo.',
      'zh': '本设备上的当前对局将结束。'
    },
    'play_visual_pick': {
      'pt': 'Mesa de quem?',
      'en': "Whose table?",
      'es': '¿Mesa de quién?',
      'zh': '谁的桌面？'
    },
    'play_visual_mine_only': {
      'pt': 'No online, muda só a sua mesa.',
      'en': 'Online, only your table changes.',
      'es': 'En línea, solo cambia tu mesa.',
      'zh': '在线时，仅更改你自己的桌面。'
    },
    'play_visual_default': {
      'pt': 'Padrão (global)',
      'en': 'Default (global)',
      'es': 'Predeterminado (global)',
      'zh': '默认（全局）'
    },
    'common_hide_nav': {
      'pt': 'Esconder menu',
      'en': 'Hide menu',
      'es': 'Ocultar menú',
      'zh': '隐藏菜单'
    },
    'nav_dashboard': {'pt': 'Painel', 'en': 'Home', 'es': 'Panel', 'zh': '首页'},
    'nav_collection': {
      'pt': 'Coleção',
      'en': 'Collection',
      'es': 'Colección',
      'zh': '收藏'
    },
    'nav_decks': {'pt': 'Decks', 'en': 'Decks', 'es': 'Mazos', 'zh': '套牌'},
    'nav_play': {'pt': 'Jogar', 'en': 'Play', 'es': 'Jugar', 'zh': '对战'},
    'nav_profiles': {
      'pt': 'Perfis',
      'en': 'Profiles',
      'es': 'Perfiles',
      'zh': '用户'
    },
    'nav_settings': {
      'pt': 'Ajustes',
      'en': 'Settings',
      'es': 'Ajustes',
      'zh': '设置'
    },
    'nav_show': {
      'pt': 'Mostrar menu',
      'en': 'Show menu',
      'es': 'Mostrar menú',
      'zh': '显示菜单'
    },
    'dash_cards': {'pt': 'Cartas', 'en': 'Cards', 'es': 'Cartas', 'zh': '牌'},
    'dash_unique': {'pt': 'Únicas', 'en': 'Unique', 'es': 'Únicas', 'zh': '不同'},
    'dash_sets': {'pt': 'Edições', 'en': 'Sets', 'es': 'Ediciones', 'zh': '系列'},
    'dash_networth': {
      'pt': 'Patrimônio',
      'en': 'Net worth',
      'es': 'Patrimonio',
      'zh': '总价值'
    },
    'dash_byrarity': {
      'pt': 'Por raridade',
      'en': 'By rarity',
      'es': 'Por rareza',
      'zh': '按稀有度'
    },
    'dash_mode': {'pt': 'Modo', 'en': 'Mode', 'es': 'Modo', 'zh': '模式'},
    'dash_top': {
      'pt': 'Mais valiosas',
      'en': 'Most valuable',
      'es': 'Más valiosas',
      'zh': '最有价值'
    },
    'dash_empty_hint': {
      'pt': 'Coleção vazia — adicione cartas na aba Coleção.',
      'en': 'Empty collection — add cards in the Collection tab.',
      'es': 'Colección vacía — añade cartas en Colección.',
      'zh': '收藏为空——去“收藏”页添加牌。'
    },
    'prof_my': {
      'pt': 'Meus perfis',
      'en': 'My profiles',
      'es': 'Mis perfiles',
      'zh': '我的用户'
    },
    'prof_friends': {
      'pt': 'Amigos',
      'en': 'Friends',
      'es': 'Amigos',
      'zh': '好友'
    },
    'prof_add': {'pt': 'Adicionar', 'en': 'Add', 'es': 'Añadir', 'zh': '添加'},
    'prof_hint': {
      'pt': 'Cadastre pelo código de convite. Amigos aparecem na aba Jogar.',
      'en': 'Add via invite code. Friends show up in the Play tab.',
      'es': 'Agrega con el código de invitación.',
      'zh': '通过邀请码添加。好友会显示在对战页。'
    },
    'prof_empty': {
      'pt':
          'Nenhum amigo ainda. Peça o código dele (aba Perfis no celular dele).',
      'en': 'No friends yet. Ask for their code (Profiles tab on their phone).',
      'es': 'Sin amigos aún. Pide su código (pestaña Perfiles).',
      'zh': '还没有好友。向对方索取代码（对方的用户页）。'
    },
    'prof_code': {'pt': 'Código', 'en': 'Code', 'es': 'Código', 'zh': '代码'},
    'prof_online': {
      'pt': 'na rede agora',
      'en': 'online now',
      'es': 'en línea ahora',
      'zh': '当前在线'
    },
    'prof_active': {'pt': 'Ativo', 'en': 'Active', 'es': 'Activo', 'zh': '当前'},
    'prof_tap': {
      'pt': 'Toque para ativar',
      'en': 'Tap to activate',
      'es': 'Toca para activar',
      'zh': '点击切换'
    },
    'prof_rename': {
      'pt': 'Renomear',
      'en': 'Rename',
      'es': 'Renombrar',
      'zh': '重命名'
    },
    'prof_copy': {
      'pt': 'Copiar código',
      'en': 'Copy code',
      'es': 'Copiar código',
      'zh': '复制代码'
    },
    'prof_delete': {
      'pt': 'Excluir',
      'en': 'Delete',
      'es': 'Eliminar',
      'zh': '删除'
    },
    'prof_new': {
      'pt': 'Novo perfil',
      'en': 'New profile',
      'es': 'Nuevo perfil',
      'zh': '新用户'
    },
    'prof_addfriend': {
      'pt': 'Adicionar amigo',
      'en': 'Add friend',
      'es': 'Añadir amigo',
      'zh': '添加好友'
    },
    'prof_name_ex': {
      'pt': 'Nome (ex. Irmão)',
      'en': 'Name (e.g. Brother)',
      'es': 'Nombre (ej. Hermano)',
      'zh': '名称（例：弟弟）'
    },
    'prof_hiscode': {
      'pt': 'Código dele (6 letras)',
      'en': 'Their code (6 letters)',
      'es': 'Su código (6 letras)',
      'zh': '对方代码（6 位字母）'
    },
    'prof_fill': {
      'pt': 'Preencha nome e código.',
      'en': 'Fill in name and code.',
      'es': 'Completa nombre y código.',
      'zh': '请填写名称和代码。'
    },
    'prof_activated': {
      'pt': 'Perfil {n} ativado.',
      'en': 'Profile {n} activated.',
      'es': 'Perfil {n} activado.',
      'zh': '用户 {n} 已激活。'
    },
    'prof_match_kept': {
      'pt': 'Perfil trocado! A partida atual continua.',
      'en': 'Profile switched! Current match continues.',
      'es': '¡Perfil cambiado! La partida actual continúa.',
      'zh': '已切换用户！当前对局继续。'
    },
    'prof_copied': {
      'pt': 'Código {c} copiado!',
      'en': 'Code {c} copied!',
      'es': '¡Código {c} copiado!',
      'zh': '代码 {c} 已复制！'
    },
    'prof_new_btn': {'pt': 'Novo', 'en': 'New', 'es': 'Nuevo', 'zh': '新建'},
    'prof_del_title': {
      'pt': 'Excluir {n}?',
      'en': 'Delete {n}?',
      'es': '¿Eliminar {n}?',
      'zh': '删除 {n}？'
    },
    'prof_del_body': {
      'pt': 'Apaga o perfil e todos os dados dele (cartas, decks, coleção).',
      'en': 'Deletes the profile and all its data (cards, decks, collection).',
      'es': 'Elimina el perfil y todos sus datos (cartas, mazos, colección).',
      'zh': '删除该用户及其所有数据（牌、套牌、收藏）。'
    },
    'prof_deleted': {
      'pt': 'Perfil excluído.',
      'en': 'Profile deleted.',
      'es': 'Perfil eliminado.',
      'zh': '用户已删除。'
    },
    'prof_nodelete': {
      'pt': 'O perfil principal não pode ser excluído.',
      'en': 'The main profile cannot be deleted.',
      'es': 'El perfil principal no se puede eliminar.',
      'zh': '主用户无法删除。'
    },
    'prof_restart': {
      'pt': 'Trocado para o principal. Reinicie para aplicar tudo.',
      'en': 'Switched to main. Restart to apply everything.',
      'es': 'Cambiado al principal. Reinicia para aplicar todo.',
      'zh': '已切换到主用户，重启后完全生效。'
    },
    'setup_title': {
      'pt': 'Vamos criar seu perfil',
      'en': "Let's create your profile",
      'es': 'Vamos a crear tu perfil',
      'zh': '创建你的用户'
    },
    'setup_sub': {
      'pt': 'Seu nome identifica suas cartas, decks e partidas neste celular.',
      'en': 'Your name identifies your cards, decks and matches on this phone.',
      'es':
          'Tu nombre identifica tus cartas, mazos y partidas en este celular.',
      'zh': '你的名称将标识此手机上的牌、套牌和对局。'
    },
    'setup_name': {
      'pt': 'Seu nome ou apelido',
      'en': 'Your name or nickname',
      'es': 'Tu nombre o apodo',
      'zh': '你的名字或昵称'
    },
    'setup_empty': {
      'pt': 'Digite um nome para continuar.',
      'en': 'Enter a name to continue.',
      'es': 'Escribe un nombre para continuar.',
      'zh': '请输入名称以继续。'
    },
    'setup_used': {
      'pt': 'Esse nome já está em uso. Tente outro.',
      'en': 'That name is already in use. Try another.',
      'es': 'Ese nombre ya está en uso. Prueba otro.',
      'zh': '该名称已被使用，请换一个。'
    },
    'setup_go': {
      'pt': 'CONTINUAR',
      'en': 'CONTINUE',
      'es': 'CONTINUAR',
      'zh': '继续'
    },
    'deck_new': {
      'pt': 'Novo deck',
      'en': 'New deck',
      'es': 'Nuevo mazo',
      'zh': '新套牌'
    },
    'deck_empty': {
      'pt': 'Nenhum deck. Toque em + para criar.',
      'en': 'No decks. Tap + to create.',
      'es': 'Sin mazos. Toca + para crear.',
      'zh': '还没有套牌，点 + 创建。'
    },
    'deck_cards_suffix': {
      'pt': 'cartas',
      'en': 'cards',
      'es': 'cartas',
      'zh': '张'
    },
    'fmt_livre': {'pt': 'Livre', 'en': 'Casual', 'es': 'Libre', 'zh': '休闲'},
    'fmt_standard': {
      'pt': 'Padrão',
      'en': 'Standard',
      'es': 'Estándar',
      'zh': '标准'
    },
    'dd_remove_last': {
      'pt': 'Remover última cópia?',
      'en': 'Remove last copy?',
      'es': '¿Eliminar última copia?',
      'zh': '移除最后一张？'
    },
    'dd_remove_q': {
      'pt': 'Remover "{n}" do deck?',
      'en': 'Remove "{n}" from the deck?',
      'es': '¿Quitar "{n}" del mazo?',
      'zh': '从套牌中移除“{n}”？'
    },
    'dd_import': {
      'pt': 'Importar lista',
      'en': 'Import list',
      'es': 'Importar lista',
      'zh': '导入列表'
    },
    'dd_import_file': {
      'pt': 'Do arquivo (.txt)',
      'en': 'From file (.txt)',
      'es': 'Desde archivo (.txt)',
      'zh': '从文件（.txt）'
    },
    'av_complete': {
      'pt': 'Completo na coleção',
      'en': 'Complete in collection',
      'es': 'Completo en la colección',
      'zh': '收藏齐全'
    },
    'av_summary': {
      'pt': '{o}/{t} cópias na coleção',
      'en': '{o}/{t} copies in collection',
      'es': '{o}/{t} copias en la colección',
      'zh': '收藏中有 {o}/{t} 张'
    },
    'av_missing_btn': {
      'pt': 'Ver faltantes',
      'en': 'See missing',
      'es': 'Ver faltantes',
      'zh': '查看缺失'
    },
    'av_missing_title': {
      'pt': 'Faltam {n} cartas',
      'en': '{n} cards missing',
      'es': 'Faltan {n} cartas',
      'zh': '缺 {n} 张牌'
    },
    'av_missing_value': {
      'pt': 'Valor aprox. do que falta: {v}',
      'en': 'Approx. value of missing: {v}',
      'es': 'Valor aprox. de lo que falta: {v}',
      'zh': '缺失部分约价值：{v}'
    },
    'av_row': {
      'pt': 'Precisa {need} • tem {owned} • faltam {missing}',
      'en': 'Need {need} • own {owned} • miss {missing}',
      'es': 'Necesita {need} • tiene {owned} • faltan {missing}',
      'zh': '需要 {need} • 拥有 {owned} • 缺 {missing}'
    },
    'av_export_txt': {
      'pt': 'TXT faltantes',
      'en': 'Missing TXT',
      'es': 'TXT faltantes',
      'zh': '缺失 TXT'
    },
    'av_export_csv': {
      'pt': 'CSV faltantes',
      'en': 'Missing CSV',
      'es': 'CSV faltantes',
      'zh': '缺失 CSV'
    },
    'stats_title': {
      'pt': 'Estatísticas',
      'en': 'Statistics',
      'es': 'Estadísticas',
      'zh': '统计'
    },
    'stats_curve': {
      'pt': 'Curva de mana',
      'en': 'Mana curve',
      'es': 'Curva de maná',
      'zh': '法术力曲线'
    },
    'stats_types': {
      'pt': 'Composição',
      'en': 'Breakdown',
      'es': 'Composición',
      'zh': '构成'
    },
    'stats_mana': {
      'pt': 'Fontes por cor (terrenos)',
      'en': 'Sources by color (lands)',
      'es': 'Fuentes por color (tierras)',
      'zh': '按颜色划分来源（地）'
    },
    'stats_lands': {
      'pt': 'terrenos',
      'en': 'lands',
      'es': 'tierras',
      'zh': '地'
    },
    'stats_sources': {
      'pt': 'fontes',
      'en': 'sources',
      'es': 'fuentes',
      'zh': '来源'
    },
    'stats_cards_sources': {
      'pt': 'cartas / fontes',
      'en': 'cards / sources',
      'es': 'cartas / fuentes',
      'zh': '牌 / 来源'
    },
    'imp_title': {
      'pt': 'Importar deck',
      'en': 'Import deck',
      'es': 'Importar mazo',
      'zh': '导入套牌'
    },
    'imp_mode_new': {
      'pt': 'Novo deck',
      'en': 'New deck',
      'es': 'Mazo nuevo',
      'zh': '新套牌'
    },
    'imp_mode_replace': {
      'pt': 'Substituir este',
      'en': 'Replace this one',
      'es': 'Reemplazar este',
      'zh': '替换本套牌'
    },
    'imp_mode_append': {
      'pt': 'Adicionar aqui',
      'en': 'Add here',
      'es': 'Añadir aquí',
      'zh': '添加到此处'
    },
    'imp_mode_sub': {
      'pt': 'Como importar a lista?',
      'en': 'How to import the list?',
      'es': '¿Cómo importar la lista?',
      'zh': '如何导入列表？'
    },
    'imp_report': {
      'pt': '{ok} identificadas • {fail} não reconhecidas',
      'en': '{ok} identified • {fail} unrecognized',
      'es': '{ok} identificadas • {fail} no reconocidas',
      'zh': '已识别 {ok} • 未识别 {fail}'
    },
    'imp_avail': {
      'pt': 'Faltam {n} cartas na coleção',
      'en': '{n} cards missing from collection',
      'es': 'Faltan {n} cartas en la colección',
      'zh': '收藏中缺 {n} 张'
    },
    'imp_unidentified': {
      'pt': 'Não reconhecidas: {n}',
      'en': 'Unrecognized: {n}',
      'es': 'No reconocidas: {n}',
      'zh': '未识别：{n}'
    },
    'imp_from_file': {
      'pt': 'Do arquivo (.txt, .json)',
      'en': 'From file (.txt, .json)',
      'es': 'Desde archivo (.txt, .json)',
      'zh': '从文件（.txt、.json）'
    },
    'imp_empty': {
      'pt': 'Nenhuma carta identificada no texto/arquivo.',
      'en': 'No cards identified in the text/file.',
      'es': 'Ninguna carta identificada en el texto/archivo.',
      'zh': '文本/文件中未识别出牌。'
    },
    'dd_export_json': {
      'pt': 'Exportar JSON',
      'en': 'Export JSON',
      'es': 'Exportar JSON',
      'zh': '导出 JSON'
    },
    'dd_imported': {
      'pt': 'Importadas: {ok}. Não encontradas: {fail}.',
      'en': 'Imported: {ok}. Not found: {fail}.',
      'es': 'Importadas: {ok}. No encontradas: {fail}.',
      'zh': '已导入：{ok}。未找到：{fail}。'
    },
    'dd_valid': {
      'pt': 'Deck válido ✓',
      'en': 'Valid deck ✓',
      'es': 'Mazo válido ✓',
      'zh': '套牌合法 ✓'
    },
    'dd_alerts': {
      'pt': '{n} alerta(s)',
      'en': '{n} warning(s)',
      'es': '{n} aviso(s)',
      'zh': '{n} 条提醒'
    },
    'dd_allok': {
      'pt': 'Tudo certo para este formato.',
      'en': 'All good for this format.',
      'es': 'Todo bien para este formato.',
      'zh': '符合该赛制。'
    },
    'dd_format': {'pt': 'Formato', 'en': 'Format', 'es': 'Formato', 'zh': '赛制'},
    'dd_cards': {'pt': 'cartas', 'en': 'cards', 'es': 'cartas', 'zh': '张'},
    'dd_unique': {'pt': 'únicas', 'en': 'unique', 'es': 'únicas', 'zh': '不同'},
    'dd_collection': {
      'pt': 'Coleção',
      'en': 'Collection',
      'es': 'Colección',
      'zh': '收藏'
    },
    'dd_search_local': {
      'pt': 'Buscar no catálogo local… (offline)',
      'en': 'Search local catalog… (offline)',
      'es': 'Buscar en el catálogo local… (sin conexión)',
      'zh': '搜索本地目录…（离线）'
    },
    'dd_search_scry': {
      'pt': 'Buscar no Scryfall… (online)',
      'en': 'Search Scryfall… (online)',
      'es': 'Buscar en Scryfall… (en línea)',
      'zh': '在 Scryfall 搜索…（在线）'
    },
    'dd_searching': {
      'pt': 'Buscando no Scryfall…',
      'en': 'Searching Scryfall…',
      'es': 'Buscando en Scryfall…',
      'zh': '正在搜索 Scryfall…'
    },
    'dd_empty': {
      'pt': 'Deck vazio. Adicione pela coleção ou Scryfall.',
      'en': 'Empty deck. Add from collection or Scryfall.',
      'es': 'Mazo vacío. Añade desde la colección o Scryfall.',
      'zh': '空套牌，从收藏或 Scryfall 添加。'
    },
    'dd_view_list': {
      'pt': 'Ver em lista',
      'en': 'List view',
      'es': 'Ver como lista',
      'zh': '列表视图'
    },
    'dd_view_grid': {
      'pt': 'Ver em grade',
      'en': 'Grid view',
      'es': 'Ver como cuadrícula',
      'zh': '网格视图'
    },
    'dd_count': {
      'pt': '{u} únicas • {t} cartas',
      'en': '{u} unique • {t} cards',
      'es': '{u} únicas • {t} cartas',
      'zh': '{u} 不同 • {t} 张'
    },
    'dd_commander_badge': {
      'pt': 'Comandante',
      'en': 'Commander',
      'es': 'Comandante',
      'zh': '指挥官'
    },
    'dd_card_options': {
      'pt': 'Opções da carta',
      'en': 'Card options',
      'es': 'Opciones de la carta',
      'zh': '卡牌选项'
    },
    'dd_validate': {
      'pt': 'Validação do formato',
      'en': 'Format validation',
      'es': 'Validación del formato',
      'zh': '赛制检查'
    },
    'dd_export': {
      'pt': 'Exportar TXT',
      'en': 'Export TXT',
      'es': 'Exportar TXT',
      'zh': '导出 TXT'
    },
    'dd_import_tip': {
      'pt': 'Importar lista',
      'en': 'Import list',
      'es': 'Importar lista',
      'zh': '导入列表'
    },
    'dd_set_commander': {
      'pt': 'Definir comandante',
      'en': 'Set as commander',
      'es': 'Definir comandante',
      'zh': '设为指挥官'
    },
    'dd_uncommander': {
      'pt': 'Remover comandante',
      'en': 'Remove commander',
      'es': 'Quitar comandante',
      'zh': '移除指挥官'
    },
    'dd_cover': {
      'pt': 'Usar como capa do deck',
      'en': 'Use as deck cover',
      'es': 'Usar como portada',
      'zh': '设为套牌封面'
    },
    'dd_uncover': {
      'pt': 'Restaurar capa automática',
      'en': 'Restore auto cover',
      'es': 'Restaurar portada automática',
      'zh': '恢复自动封面'
    },
    'dd_remove_from': {
      'pt': 'Remover do deck',
      'en': 'Remove from deck',
      'es': 'Quitar del mazo',
      'zh': '从套牌移除'
    },
    'dd_starting': {
      'pt': 'Iniciando…',
      'en': 'Starting…',
      'es': 'Iniciando…',
      'zh': '开始…'
    },
    'dd_qty': {'pt': 'qtd', 'en': 'qty', 'es': 'cant.', 'zh': '数量'},
    'dd_owned': {
      'pt': 'Você tem {o} na coleção.',
      'en': 'You own {o} in your collection.',
      'es': 'Tienes {o} en tu colección.',
      'zh': '你的收藏中有 {o} 张。'
    },
    'dd_added': {
      'pt': 'Carta adicionada ao deck',
      'en': 'Card added to the deck',
      'es': 'Carta añadida al mazo',
      'zh': '已加入套牌'
    },
    'dd_notfound': {
      'pt': '"{q}" não encontrada no Scryfall. Tente o nome em inglês.',
      'en': '"{q}" not found on Scryfall. Try the English name.',
      'es': '"{q}" no encontrada en Scryfall. Prueba en inglés.',
      'zh': '在 Scryfall 未找到“{q}”，请试英文名。'
    },
    'dd_fail_net': {
      'pt': 'Falha no Scryfall. Verifique sua internet. ({e})',
      'en': 'Scryfall failed. Check your connection. ({e})',
      'es': 'Falló Scryfall. Revisa tu conexión. ({e})',
      'zh': 'Scryfall 失败，请检查网络。({e})'
    },
    'dd_commander_set': {
      'pt': 'Comandante definido',
      'en': 'Commander set',
      'es': 'Comandante definido',
      'zh': '已设置指挥官'
    },
    'dd_cover_auto': {
      'pt': 'Capa automática restaurada',
      'en': 'Auto cover restored',
      'es': 'Portada automática restaurada',
      'zh': '已恢复自动封面'
    },
    'dd_cover_set': {
      'pt': 'Capa do deck definida',
      'en': 'Deck cover set',
      'es': 'Portada definida',
      'zh': '已设置套牌封面'
    },
    'dd_error': {
      'pt': 'Erro: {e}',
      'en': 'Error: {e}',
      'es': 'Error: {e}',
      'zh': '错误：{e}'
    },
    'dd_nothing': {
      'pt': 'Nada encontrado no Scryfall para "{q}"',
      'en': 'Nothing found on Scryfall for "{q}"',
      'es': 'Nada encontrado en Scryfall para "{q}"',
      'zh': '在 Scryfall 未找到“{q}”'
    },
    'dd_nothing_lang': {
      'pt': 'Nada em {l} no Scryfall para "{q}". Tente "Todos".',
      'en': 'Nothing in {l} on Scryfall for "{q}". Try "All".',
      'es': 'Nada en {l} en Scryfall para "{q}". Prueba "Todos".',
      'zh': '在 Scryfall 的{l}中未找到“{q}”，请试“全部”。'
    },
    'dd_v_need': {
      'pt': 'Faltam {a} cartas (mínimo {b}).',
      'en': 'Missing {a} cards (minimum {b}).',
      'es': 'Faltan {a} cartas (mínimo {b}).',
      'zh': '还差 {a} 张（最少 {b} 张）。'
    },
    'dd_v_over': {
      'pt': 'Passou do limite: {t}/{m} cartas.',
      'en': 'Over the limit: {t}/{m} cards.',
      'es': 'Sobre el límite: {t}/{m} cartas.',
      'zh': '超出上限：{t}/{m} 张。'
    },
    'dd_v_copies': {
      'pt': '"{n}" tem {q} cópias (máximo {c}).',
      'en': '"{n}" has {q} copies (max {c}).',
      'es': '"{n}" tiene {q} copias (máximo {c}).',
      'zh': '“{n}”有 {q} 张（上限 {c}）。'
    },
    'dd_v_commander': {
      'pt': 'Escolha um comandante.',
      'en': 'Choose a commander.',
      'es': 'Elige un comandante.',
      'zh': '请选择指挥官。'
    },
    'dd_v_commander_nf': {
      'pt': 'Comandante não encontrado.',
      'en': 'Commander not found.',
      'es': 'Comandante no encontrado.',
      'zh': '未找到指挥官。'
    },
    'dd_v_commander_leg': {
      'pt': 'Comandante deve ser lendário ("{n}").',
      'en': 'Commander must be legendary ("{n}").',
      'es': 'El comandante debe ser legendario ("{n}").',
      'zh': '指挥官必须是传奇（“{n}”）。'
    },
    'dd_v_identity': {
      'pt': '"{n}" fora da identidade de cor ({o}).',
      'en': '"{n}" outside the color identity ({o}).',
      'es': '"{n}" fuera de la identidad de color ({o}).',
      'zh': '“{n}”超出颜色特性（{o}）。'
    },
    'dd_v_pauper': {
      'pt': '"{n}" não é comum.',
      'en': '"{n}" is not a common.',
      'es': '"{n}" no es común.',
      'zh': '“{n}”不是普通牌。'
    },
    'rar_all': {'pt': 'Todas', 'en': 'All', 'es': 'Todas', 'zh': '全部'},
    'rar_common': {'pt': 'Comum', 'en': 'Common', 'es': 'Común', 'zh': '普通'},
    'rar_uncommon': {
      'pt': 'Incomum',
      'en': 'Uncommon',
      'es': 'Infrecuente',
      'zh': '非普通'
    },
    'rar_rare': {'pt': 'Rara', 'en': 'Rare', 'es': 'Rara', 'zh': '稀有'},
    'rar_mythic': {'pt': 'Mítica', 'en': 'Mythic', 'es': 'Mítica', 'zh': '秘稀'},
    'col_white': {'pt': 'Branca', 'en': 'White', 'es': 'Blanca', 'zh': '白色'},
    'col_blue': {'pt': 'Azul', 'en': 'Blue', 'es': 'Azul', 'zh': '蓝色'},
    'col_black': {'pt': 'Preta', 'en': 'Black', 'es': 'Negra', 'zh': '黑色'},
    'col_red': {'pt': 'Vermelha', 'en': 'Red', 'es': 'Roja', 'zh': '红色'},
    'col_green': {'pt': 'Verde', 'en': 'Green', 'es': 'Verde', 'zh': '绿色'},
    'col_multi': {
      'pt': 'Multicolor',
      'en': 'Multicolor',
      'es': 'Multicolor',
      'zh': '多色'
    },
    'col_colorless': {
      'pt': 'Incolor',
      'en': 'Colorless',
      'es': 'Incolora',
      'zh': '无色'
    },
    'cl_type2': {
      'pt': 'Digite ao menos 2 letras para buscar',
      'en': 'Type at least 2 letters to search',
      'es': 'Escribe al menos 2 letras para buscar',
      'zh': '请至少输入 2 个字符进行搜索'
    },
    'cl_added_now': {
      'pt': '"{n}" adicionada (agora {q})',
      'en': '"{n}" added (now {q})',
      'es': '"{n}" añadida (ahora {q})',
      'zh': '已添加“{n}”（现有 {q}）'
    },
    'cl_added': {
      'pt': '"{n}" adicionada à coleção',
      'en': '"{n}" added to collection',
      'es': '"{n}" añadida a la colección',
      'zh': '“{n}”已加入收藏'
    },
    'cl_add_error': {
      'pt': 'Erro ao adicionar: {e}',
      'en': 'Failed to add: {e}',
      'es': 'Error al añadir: {e}',
      'zh': '添加失败：{e}'
    },
    'cl_no_version': {
      'pt': '"{n}" não tem versão em {l}. Troque o idioma.',
      'en': '"{n}" has no {l} version. Switch language.',
      'es': '"{n}" no tiene versión en {l}. Cambia el idioma.',
      'zh': '“{n}”没有{l}版本，请切换语言。'
    },
    'cl_notfound': {
      'pt': 'Carta não encontrada no Scryfall',
      'en': 'Card not found on Scryfall',
      'es': 'Carta no encontrada en Scryfall',
      'zh': '在 Scryfall 未找到该牌'
    },
    'cl_photo': {
      'pt': 'Modo foto: escanear carta',
      'en': 'Photo mode: scan a card',
      'es': 'Modo foto: escanear carta',
      'zh': '拍照模式：扫描牌'
    },
    'cl_sort': {'pt': 'Ordenar', 'en': 'Sort', 'es': 'Ordenar', 'zh': '排序'},
    'cl_sort_name': {
      'pt': 'Nome A–Z',
      'en': 'Name A–Z',
      'es': 'Nombre A–Z',
      'zh': '名称 A–Z'
    },
    'cl_sort_value': {
      'pt': 'Maior valor',
      'en': 'Highest value',
      'es': 'Mayor valor',
      'zh': '价值最高'
    },
    'cl_sort_set': {'pt': 'Edição', 'en': 'Set', 'es': 'Edición', 'zh': '系列'},
    'cl_sort_qty': {
      'pt': 'Quantidade',
      'en': 'Quantity',
      'es': 'Cantidad',
      'zh': '数量'
    },
    'cl_export': {
      'pt': 'Exportar',
      'en': 'Export',
      'es': 'Exportar',
      'zh': '导出'
    },
    'cl_exp_csv': {
      'pt': 'Exportar CSV',
      'en': 'Export CSV',
      'es': 'Exportar CSV',
      'zh': '导出 CSV'
    },
    'cl_exp_json': {
      'pt': 'Exportar JSON',
      'en': 'Export JSON',
      'es': 'Exportar JSON',
      'zh': '导出 JSON'
    },
    'cl_exp_txt': {
      'pt': 'Exportar TXT',
      'en': 'Export TXT',
      'es': 'Exportar TXT',
      'zh': '导出 TXT'
    },
    'cl_tab_count': {
      'pt': 'Coleção ({n})',
      'en': 'Collection ({n})',
      'es': 'Colección ({n})',
      'zh': '收藏（{n}）'
    },
    'cl_tab_add': {'pt': 'Adicionar', 'en': 'Add', 'es': 'Añadir', 'zh': '添加'},
    'cl_search_local': {
      'pt': 'Buscar na minha coleção…',
      'en': 'Search my collection…',
      'es': 'Buscar en mi colección…',
      'zh': '搜索我的收藏…'
    },
    'cl_filters': {
      'pt': 'Filtros',
      'en': 'Filters',
      'es': 'Filtros',
      'zh': '筛选'
    },
    'cl_filters_on': {
      'pt': 'Filtros (ativos)',
      'en': 'Filters (on)',
      'es': 'Filtros (activos)',
      'zh': '筛选（已启用）'
    },
    'cl_n_cards': {
      'pt': '{n} cartas',
      'en': '{n} cards',
      'es': '{n} cartas',
      'zh': '{n} 张'
    },
    'cl_empty_filter': {
      'pt': 'Nada na coleção com esse filtro.',
      'en': 'Nothing in the collection with these filters.',
      'es': 'Nada en la colección con este filtro.',
      'zh': '收藏中没有符合筛选的牌。'
    },
    'cl_scry_btn': {
      'pt': 'Buscar no Scryfall',
      'en': 'Search Scryfall',
      'es': 'Buscar en Scryfall',
      'zh': '在 Scryfall 搜索'
    },
    'cl_rarity': {
      'pt': 'Raridade',
      'en': 'Rarity',
      'es': 'Rareza',
      'zh': '稀有度'
    },
    'cl_color': {'pt': 'Cor', 'en': 'Color', 'es': 'Color', 'zh': '颜色'},
    'cl_set': {'pt': 'Edição', 'en': 'Set', 'es': 'Edición', 'zh': '系列'},
    'cl_all': {'pt': 'Todos', 'en': 'All', 'es': 'Todos', 'zh': '全部'},
    'cl_type_ex': {
      'pt': 'Tipo (ex. Elfo)',
      'en': 'Type (e.g. Elf)',
      'es': 'Tipo (ej. Elfo)',
      'zh': '类别（例：精灵）'
    },
    'cl_fav': {
      'pt': 'Favoritas',
      'en': 'Favorites',
      'es': 'Favoritas',
      'zh': '收藏'
    },
    'cl_clear': {'pt': 'Limpar', 'en': 'Clear', 'es': 'Limpiar', 'zh': '清除'},
    'cl_scry_hint': {
      'pt': 'Nome em PT ou EN… (ex. Relâmpago)',
      'en': 'Name… (e.g. Lightning Bolt)',
      'es': 'Nombre… (ej. Relámpago)',
      'zh': '牌名…（例：闪电击）'
    },
    'cl_lang': {
      'pt': 'Idioma:',
      'en': 'Language:',
      'es': 'Idioma:',
      'zh': '语言：'
    },
    'cl_adding': {
      'pt': 'Adicionando…',
      'en': 'Adding…',
      'es': 'Añadiendo…',
      'zh': '添加中…'
    },
    'cl_scry_empty': {
      'pt': 'Busque cartas para adicionar à coleção.',
      'en': 'Search cards to add to your collection.',
      'es': 'Busca cartas para añadir a tu colección.',
      'zh': '搜索牌以加入收藏。'
    },
    'cl_add': {'pt': 'Adicionar', 'en': 'Add', 'es': 'Añadir', 'zh': '添加'},
    'cd_cost': {'pt': 'Custo', 'en': 'Cost', 'es': 'Coste', 'zh': '费用'},
    'cd_qty': {
      'pt': 'Quantidade',
      'en': 'Quantity',
      'es': 'Cantidad',
      'zh': '数量'
    },
    'pm_noread': {
      'pt': 'Não consegui ler o nome. Aproxime e centralize o título.',
      'en': "Couldn't read the name. Move closer and center the title.",
      'es': 'No pude leer el nombre. Acerca y centra el título.',
      'zh': '无法读取名称，请靠近并对准标题。'
    },
    'pm_readfail': {
      'pt': 'Falha na leitura: {e}',
      'en': 'Read failed: {e}',
      'es': 'Falló la lectura: {e}',
      'zh': '读取失败：{e}'
    },
    'pm_perm': {
      'pt': 'Permissão da câmera negada.',
      'en': 'Camera permission denied.',
      'es': 'Permiso de cámara denegado.',
      'zh': '相机权限被拒绝。'
    },
    'pm_nocam': {
      'pt': 'Nenhuma câmera encontrada.',
      'en': 'No camera found.',
      'es': 'Ninguna cámara encontrada.',
      'zh': '未找到相机。'
    },
    'pm_camfail': {
      'pt': 'Falha na câmera: {e}',
      'en': 'Camera failed: {e}',
      'es': 'Falló la cámara: {e}',
      'zh': '相机故障：{e}'
    },
    'pm_reading': {
      'pt': 'Lendo a carta…',
      'en': 'Reading the card…',
      'es': 'Leyendo la carta…',
      'zh': '正在读取牌…'
    },
    'pm_recognizing': {
      'pt': 'Reconhecendo o nome…',
      'en': 'Recognizing the name…',
      'es': 'Reconociendo el nombre…',
      'zh': '正在识别名称…'
    },
    'pm_loading_prints': {
      'pt': 'Carregando impressões…',
      'en': 'Loading printings…',
      'es': 'Cargando impresiones…',
      'zh': '正在加载版本…'
    },
    'pm_prints_one': {
      'pt': 'Impressão (nº {n} detectado):',
      'en': 'Printing (no. {n} detected):',
      'es': 'Impresión (n.º {n} detectado):',
      'zh': '版本（检测到编号 {n}）：'
    },
    'pm_prints': {
      'pt': 'Impressões:',
      'en': 'Printings:',
      'es': 'Impresiones:',
      'zh': '版本：'
    },
    'pm_title': {
      'pt': 'Modo foto',
      'en': 'Photo mode',
      'es': 'Modo foto',
      'zh': '拍照模式'
    },
    'pm_title_added': {
      'pt': 'Modo foto ({n} adicionadas)',
      'en': 'Photo mode ({n} added)',
      'es': 'Modo foto ({n} añadidas)',
      'zh': '拍照模式（已添加 {n}）'
    },
    'pm_focus_hint': {
      'pt': 'Toque na carta para focar • alinhe o título',
      'en': 'Tap the card to focus • align the title',
      'es': 'Toca la carta para enfocar • alinea el título',
      'zh': '点击牌进行对焦 • 对准标题'
    },
    'pm_torch_on': {
      'pt': 'Desligar lanterna',
      'en': 'Turn flashlight off',
      'es': 'Apagar linterna',
      'zh': '关闭手电筒'
    },
    'pm_torch_off': {
      'pt': 'Ligar lanterna',
      'en': 'Turn flashlight on',
      'es': 'Encender linterna',
      'zh': '打开手电筒'
    },
    'pm_detected': {
      'pt': 'Detectado na carta: ',
      'en': 'Detected on card: ',
      'es': 'Detectado en la carta: ',
      'zh': '在牌上检测到：'
    },
    'pm_name_read': {
      'pt': 'Nome lido (toque para corrigir):',
      'en': 'Read name (tap to fix):',
      'es': 'Nombre leído (toca para corregir):',
      'zh': '读取的名称（点击更正）：'
    },
    'pm_name_hint': {
      'pt': 'Nome da carta…',
      'en': 'Card name…',
      'es': 'Nombre de la carta…',
      'zh': '牌名…'
    },
    'pm_other': {
      'pt': 'Outras cartas:',
      'en': 'Other cards:',
      'es': 'Otras cartas:',
      'zh': '其他牌：'
    },
    'pm_add_button': {
      'pt': 'ADICIONAR À COLEÇÃO',
      'en': 'ADD TO COLLECTION',
      'es': 'AÑADIR A LA COLECCIÓN',
      'zh': '加入收藏'
    },
    'pm_back': {
      'pt': 'Voltar à câmera',
      'en': 'Back to camera',
      'es': 'Volver a la cámara',
      'zh': '返回相机'
    },
    'su_how': {
      'pt': 'Como vocês vão jogar?',
      'en': 'How will you play?',
      'es': '¿Cómo van a jugar?',
      'zh': '你们怎么玩？'
    },
    'su_one': {
      'pt': 'Um aparelho',
      'en': 'One device',
      'es': 'Un aparato',
      'zh': '一台设备'
    },
    'su_each': {
      'pt': 'Cada um no seu celular',
      'en': 'Each on their own phone',
      'es': 'Cada uno en su celular',
      'zh': '每人用自己的手机'
    },
    'su_lan': {'pt': 'LAN', 'en': 'LAN', 'es': 'LAN', 'zh': 'LAN'},
    'su_local': {'pt': 'Local', 'en': 'Local', 'es': 'Local', 'zh': '本地'},
    'su_lan_hint': {
      'pt':
          'Abra uma mesa no primeiro celular. Cada pessoa entra pelo IP usando o nome do próprio perfil — não existem jogadores preenchidos manualmente.',
      'en':
          'Host a table on the first phone. Everyone joins via IP with their own profile name.',
      'es':
          'Abre una mesa en el primer celular. Cada uno entra por IP con su perfil.',
      'zh': '在第一台手机上开桌，每人用自己的用户名通过 IP 加入。'
    },
    'su_who': {
      'pt': 'Quem joga?',
      'en': 'Who is playing?',
      'es': '¿Quién juega?',
      'zh': '谁玩？'
    },
    'su_player': {'pt': 'Jogador', 'en': 'Player', 'es': 'Jugador', 'zh': '玩家'},
    'su_you': {'pt': 'Você', 'en': 'You', 'es': 'Tú', 'zh': '你'},
    'su_host_name': {
      'pt': 'Anfitrião',
      'en': 'Host',
      'es': 'Anfitrión',
      'zh': '主机'
    },
    'su_guest': {
      'pt': 'Convidado',
      'en': 'Guest',
      'es': 'Invitado',
      'zh': '访客'
    },
    'su_tap_friend': {
      'pt': 'Toque num amigo para preencher:',
      'en': 'Tap a friend to fill in:',
      'es': 'Toca un amigo para completar:',
      'zh': '点击好友以填充：'
    },
    'su_start': {
      'pt': 'COMEÇAR PARTIDA',
      'en': 'START MATCH',
      'es': 'EMPEZAR PARTIDA',
      'zh': '开始对局'
    },
    'su_foot': {
      'pt':
          'No modo de um aparelho, o primeiro jogador fica embaixo e o segundo em cima. No modo Wi‑Fi, a mesa fica sincronizada em todos os celulares.',
      'en':
          'On one device, player one sits at the bottom. On Wi-Fi, the table syncs across phones.',
      'es':
          'En un aparato, el primero abajo y el segundo arriba. En Wi-Fi, la mesa se sincroniza.',
      'zh': '单设备模式下，一号玩家在下方；Wi-Fi 模式下桌面在所有手机同步。'
    },
    'su_format': {'pt': 'Formato', 'en': 'Format', 'es': 'Formato', 'zh': '赛制'},
    'su_life_of': {
      'pt': '{n} ({l} de vida)',
      'en': '{n} ({l} life)',
      'es': '{n} ({l} vidas)',
      'zh': '{n}（{l} 生命）'
    },
    'su_startlife': {
      'pt': 'Vida inicial: ',
      'en': 'Starting life: ',
      'es': 'Vidas iniciales: ',
      'zh': '初始生命：'
    },
    'su_players': {
      'pt': 'Jogadores: ',
      'en': 'Players: ',
      'es': 'Jugadores: ',
      'zh': '玩家：'
    },
    'su_table': {
      'pt': 'Visual da mesa',
      'en': 'Table theme',
      'es': 'Aspecto de la mesa',
      'zh': '桌面外观'
    },
    'su_table_sub': {
      'pt': 'Muda o fundo, a borda das fichas e o destaque da vida.',
      'en': 'Changes background, token borders and life highlight.',
      'es': 'Cambia fondo, bordes y destaque de vidas.',
      'zh': '更改背景、衍生物边框和生命高亮。'
    },
    'su_net': {
      'pt': 'Mesa em rede (mesmo Wi-Fi)',
      'en': 'Network table (same Wi-Fi)',
      'es': 'Mesa en red (mismo Wi-Fi)',
      'zh': '局域网桌面（同一 Wi-Fi）'
    },
    'su_net_sub': {
      'pt': 'Um hospeda, os outros entram pelo IP. Sem internet.',
      'en': 'One hosts, others join via IP. No internet needed.',
      'es': 'Uno hospeda, los otros entran por IP. Sin internet.',
      'zh': '一人开桌，其他人通过 IP 加入，无需互联网。'
    },
    'su_host': {'pt': 'Hospedar', 'en': 'Host', 'es': 'Hospedar', 'zh': '开桌'},
    'su_join': {'pt': 'Entrar', 'en': 'Join', 'es': 'Entrar', 'zh': '加入'},
    'su_invite_btn': {
      'pt': 'Convidar',
      'en': 'Invite',
      'es': 'Invitar',
      'zh': '邀请'
    },
    'su_fake': {
      'pt': '+ fake p/ teste',
      'en': '+ fake for testing',
      'es': '+ falso p/ probar',
      'zh': '+ 测试假人'
    },
    'lan_fake': {'pt': 'fake', 'en': 'fake', 'es': 'falso', 'zh': '假人'},
    'lan_players': {
      'pt': 'Jogadores',
      'en': 'Players',
      'es': 'Jugadores',
      'zh': '玩家'
    },
    'on_title': {'pt': 'Online', 'en': 'Online', 'es': 'Online', 'zh': '在线'},
    'on_net': {
      'pt': 'Sala online (pela internet)',
      'en': 'Online room (over the internet)',
      'es': 'Sala en línea (por internet)',
      'zh': '在线房间（互联网）'
    },
    'on_net_sub': {
      'pt': 'Um cria a sala, os outros entram com o código.',
      'en': 'One creates the room, others join with the code.',
      'es': 'Uno crea la sala, los otros entran con el código.',
      'zh': '一人建房，其他人凭代码加入。'
    },
    'on_hint': {
      'pt':
          'O anfitrião cria a sala e passa o código. Quem entra aguarda ele começar a partida.',
      'en':
          'The host creates the room and shares the code. Guests wait for the host to start.',
      'es':
          'El anfitrión crea la sala y pasa el código. Los demás esperan el inicio.',
      'zh': '房主建房并分享代码，其他人等待开始。'
    },
    'on_create': {
      'pt': 'Criar sala',
      'en': 'Create room',
      'es': 'Crear sala',
      'zh': '创建房间'
    },
    'on_code_hint': {
      'pt': 'Código (ex. ABC123)',
      'en': 'Code (e.g. ABC123)',
      'es': 'Código (ej. ABC123)',
      'zh': '代码（例：ABC123）'
    },
    'on_waiting': {
      'pt': 'Aguardando jogadores… passe o código!',
      'en': 'Waiting for players… share the code!',
      'es': 'Esperando jugadores… ¡pasa el código!',
      'zh': '等待玩家…分享代码！'
    },
    'on_players': {
      'pt': 'Jogadores',
      'en': 'Players',
      'es': 'Jugadores',
      'zh': '玩家'
    },
    'on_wait_dot': {
      'pt': '○ Aguardando...',
      'en': '○ Waiting...',
      'es': '○ Esperando...',
      'zh': '○ 等待中…'
    },
    'on_late': {
      'pt': 'Entrada tardia',
      'en': 'Late join',
      'es': 'Entrada tardía',
      'zh': '迟到加入'
    },
    'on_late_sub': {
      'pt': 'Novos jogadores podem entrar com a partida rolando',
      'en': 'New players may join mid-match',
      'es': 'Nuevos jugadores pueden entrar con la partida en curso',
      'zh': '新玩家可在对局中加入'
    },
    'on_st_open': {
      'pt': 'Em andamento • aberta',
      'en': 'Ongoing • open',
      'es': 'En curso • abierta',
      'zh': '进行中•开放'
    },
    'on_st_locked': {
      'pt': 'Em andamento • fechada',
      'en': 'Ongoing • locked',
      'es': 'En curso • cerrada',
      'zh': '进行中•锁定'
    },
    'on_st_full': {'pt': 'Cheia', 'en': 'Full', 'es': 'Llena', 'zh': '已满'},
    'on_count': {
      'pt': '{n}/{m}',
      'en': '{n}/{m}',
      'es': '{n}/{m}',
      'zh': '{n}/{m}'
    },
    'on_start': {
      'pt': 'Começar partida',
      'en': 'Start match',
      'es': 'Empezar partida',
      'zh': '开始对局'
    },
    'on_need2': {
      'pt': 'É preciso ao menos 2 jogadores.',
      'en': 'At least 2 players are needed.',
      'es': 'Se necesitan al menos 2 jugadores.',
      'zh': '至少需要 2 名玩家。'
    },
    'on_leave': {
      'pt': 'Sair da sala',
      'en': 'Leave room',
      'es': 'Salir de la sala',
      'zh': '离开房间'
    },
    'on_sync': {
      'pt': 'Sincronizando…',
      'en': 'Syncing…',
      'es': 'Sincronizando…',
      'zh': '同步中…'
    },
    'on_created': {
      'pt': 'Sala {c} criada! Passe o código.',
      'en': 'Room {c} created! Share the code.',
      'es': '¡Sala {c} creada! Pasa el código.',
      'zh': '房间 {c} 已创建！分享代码。'
    },
    'on_joined': {
      'pt': 'Entrou na sala {c}!',
      'en': 'Joined room {c}!',
      'es': '¡Entraste a la sala {c}!',
      'zh': '已加入房间 {c}！'
    },
    'on_fail': {
      'pt': 'Falha online: {e}',
      'en': 'Online failed: {e}',
      'es': 'Falló en línea: {e}',
      'zh': '在线失败：{e}'
    },
    'on_reconnect_fail': {
      'pt': 'Não foi possível reconectar: {e}',
      'en': "Couldn't reconnect: {e}",
      'es': 'No se pudo reconectar: {e}',
      'zh': '无法重连：{e}'
    },
    'on_you': {'pt': '(você)', 'en': '(you)', 'es': '(tú)', 'zh': '（你）'},
    'on_wait_host': {
      'pt': 'Aguarde o anfitrião começar…',
      'en': 'Wait for the host to start…',
      'es': 'Espera a que el anfitrión empiece…',
      'zh': '等待房主开始…'
    },
    'on_room': {'pt': 'Sala', 'en': 'Room', 'es': 'Sala', 'zh': '房间'},
    'on_connected_n': {
      'pt': 'online',
      'en': 'online',
      'es': 'en línea',
      'zh': '在线'
    },
    'on_conn_title': {
      'pt': 'Conexão',
      'en': 'Connection',
      'es': 'Conexión',
      'zh': '连接'
    },
    'on_conn_room': {'pt': 'Sala', 'en': 'Room', 'es': 'Sala', 'zh': '房间'},
    'on_conn_as': {
      'pt': 'Você está conectado como',
      'en': 'You are connected as',
      'es': 'Estás conectado como',
      'zh': '你的连接身份'
    },
    'on_conn_profile': {
      'pt': 'Perfil atualmente selecionado',
      'en': 'Currently selected profile',
      'es': 'Perfil seleccionado ahora',
      'zh': '当前所选用户'
    },
    'on_conn_net': {
      'pt': 'Conexão',
      'en': 'Connection',
      'es': 'Conexión',
      'zh': '连接'
    },
    'on_conn_players': {
      'pt': 'Jogadores',
      'en': 'Players',
      'es': 'Jugadores',
      'zh': '玩家'
    },
    'on_kicked': {
      'pt': 'Você foi removido da sala.',
      'en': 'You were removed from the room.',
      'es': 'Fuiste eliminado de la sala.',
      'zh': '你被移出了房间。'
    },
    'on_one_room': {
      'pt': 'Já existe uma sala ativa. Saia dela primeiro.',
      'en': 'There is already an active room. Leave it first.',
      'es': 'Ya hay una sala activa. Sal primero.',
      'zh': '已有活跃房间，请先离开。'
    },
    'on_other_room': {
      'pt': 'Há outra sala ativa. Saia dela primeiro.',
      'en': 'Another room is active. Leave it first.',
      'es': 'Hay otra sala activa. Sal primero.',
      'zh': '有另一个活跃房间，请先离开。'
    },
    'on_max_sessions': {
      'pt': 'Máximo de 6 sessões por aparelho.',
      'en': 'Maximum 6 sessions per device.',
      'es': 'Máximo 6 sesiones por aparato.',
      'zh': '每台设备最多 6 个会话。'
    },
    'on_same_profile': {
      'pt': 'Este perfil já está conectado em outra sessão.',
      'en': 'This profile is already connected in another session.',
      'es': 'Este perfil ya está conectado en otra sesión.',
      'zh': '此用户已在另一会话中连接。'
    },
    'on_fail_offline': {
      'pt': 'Sem conexão com a sala.',
      'en': 'No connection to the room.',
      'es': 'Sin conexión a la sala.',
      'zh': '未连接到房间。'
    },
    'on_fail_send': {
      'pt': 'Não foi possível enviar a ação.',
      'en': "Couldn't send the action.",
      'es': 'No se pudo enviar la acción.',
      'zh': '无法发送操作。'
    },
    'on_session_n': {
      'pt': 'Sessão Online {n}',
      'en': 'Online Session {n}',
      'es': 'Sesión en línea {n}',
      'zh': '在线会话 {n}'
    },
    'on_as': {
      'pt': 'Jogando como: {n}',
      'en': 'Playing as: {n}',
      'es': 'Jugando como: {n}',
      'zh': '当前身份：{n}'
    },
    'on_st_connected': {
      'pt': 'conectado',
      'en': 'connected',
      'es': 'conectado',
      'zh': '已连接'
    },
    'on_st_waiting': {
      'pt': 'aguardando',
      'en': 'waiting',
      'es': 'en espera',
      'zh': '等待中'
    },
    'on_connect_profile': {
      'pt': 'Conectar este perfil',
      'en': 'Connect this profile',
      'es': 'Conectar este perfil',
      'zh': '连接此用户'
    },
    'fr_online': {
      'pt': 'Amigos online',
      'en': 'Online friends',
      'es': 'Amigos en línea',
      'zh': '在线好友'
    },
    'fr_code': {
      'pt': 'Seu código',
      'en': 'Your code',
      'es': 'Tu código',
      'zh': '你的代码'
    },
    'fr_add_hint': {
      'pt': 'Código do amigo (ex. MC-XXXXX)',
      'en': 'Friend code (e.g. MC-XXXXX)',
      'es': 'Código de amigo (ej. MC-XXXXX)',
      'zh': '好友代码（例：MC-XXXXX）'
    },
    'fr_add': {'pt': 'Adicionar', 'en': 'Add', 'es': 'Añadir', 'zh': '添加'},
    'fr_requests': {
      'pt': 'Pedidos de amizade',
      'en': 'Friend requests',
      'es': 'Solicitudes de amistad',
      'zh': '好友请求'
    },
    'fr_accept': {'pt': 'Aceitar', 'en': 'Accept', 'es': 'Aceptar', 'zh': '接受'},
    'fr_decline': {
      'pt': 'Recusar',
      'en': 'Decline',
      'es': 'Rechazar',
      'zh': '拒绝'
    },
    'fr_empty': {
      'pt': 'Nenhum amigo online ainda. Compartilhe seu código!',
      'en': 'No online friends yet. Share your code!',
      'es': 'Sin amigos en línea. ¡Comparte tu código!',
      'zh': '还没有在线好友，分享你的代码吧！'
    },
    'fr_playing': {
      'pt': 'Jogando',
      'en': 'Playing',
      'es': 'Jugando',
      'zh': '游戏中'
    },
    'fr_available': {
      'pt': 'Disponível',
      'en': 'Available',
      'es': 'Disponible',
      'zh': '在线'
    },
    'fr_offline': {
      'pt': 'Offline',
      'en': 'Offline',
      'es': 'Desconectado',
      'zh': '离线'
    },
    'fr_sent': {
      'pt': 'Pedido enviado!',
      'en': 'Request sent!',
      'es': '¡Solicitud enviada!',
      'zh': '请求已发送！'
    },
    'fr_accepted': {
      'pt': 'Amigo adicionado!',
      'en': 'Friend added!',
      'es': '¡Amigo añadido!',
      'zh': '已添加好友！'
    },
    'fr_removed': {
      'pt': 'Amigo removido.',
      'en': 'Friend removed.',
      'es': 'Amigo eliminado.',
      'zh': '已移除好友。'
    },
    'fr_notfound': {
      'pt': 'Código não encontrado.',
      'en': 'Code not found.',
      'es': 'Código no encontrado.',
      'zh': '未找到该代码。'
    },
    'fr_invite_title': {
      'pt': 'Convidar para a sala',
      'en': 'Invite to the room',
      'es': 'Invitar a la sala',
      'zh': '邀请加入房间'
    },
    'fr_invite_empty': {
      'pt': 'Sem amigos para convidar.',
      'en': 'No friends to invite.',
      'es': 'Sin amigos para invitar.',
      'zh': '没有可邀请的好友。'
    },
    'fr_invite_send': {
      'pt': 'Enviar convite',
      'en': 'Send invite',
      'es': 'Enviar invitación',
      'zh': '发送邀请'
    },
    'fr_invite_sent': {
      'pt': 'Convite enviado!',
      'en': 'Invite sent!',
      'es': '¡Invitación enviada!',
      'zh': '邀请已发送！'
    },
    'fr_invites': {
      'pt': 'Convites para salas',
      'en': 'Room invites',
      'es': 'Invitaciones a salas',
      'zh': '房间邀请'
    },
    'fr_enter': {'pt': 'Entrar', 'en': 'Join', 'es': 'Entrar', 'zh': '加入'},
    'fr_rooms': {
      'pt': 'Salas dos amigos',
      'en': "Friends' rooms",
      'es': 'Salas de amigos',
      'zh': '好友的房间'
    },
    'fr_invite_body': {
      'pt': '{n} convidou você para uma partida Online.',
      'en': '{n} invited you to an Online match.',
      'es': '{n} te invitó a una partida en línea.',
      'zh': '{n} 邀请你进行在线对局。'
    },
    'on_session_mismatch': {
      'pt': 'Sala conectada como {s}. Perfil atual: {p}.',
      'en': 'Room connected as {s}. Current profile: {p}.',
      'es': 'Sala conectada como {s}. Perfil actual: {p}.',
      'zh': '房间连接身份为 {s}，当前用户为 {p}。'
    },
    'su_waiting': {
      'pt': 'Aguardando oponente…',
      'en': 'Waiting for opponent…',
      'es': 'Esperando rival…',
      'zh': '等待对手…'
    },
    'su_wait_hint': {
      'pt': 'Convide pela lista "Na mesma rede" ou passe o IP da mesa.',
      'en': 'Invite from the "On the same network" list or share the table IP.',
      'es': 'Invita desde "En la misma red" o pasa la IP.',
      'zh': '从“同一网络”列表邀请或分享桌面 IP。'
    },
    'su_other_ip': {
      'pt': 'Outro IP',
      'en': 'Other IP',
      'es': 'Otra IP',
      'zh': '其他 IP'
    },
    'su_connected': {
      'pt': 'Conectados: {n} — passe esse IP p/ o outro celular.',
      'en': 'Connected: {n} — share this IP with the other phone.',
      'es': 'Conectados: {n} — pasa esta IP al otro celular.',
      'zh': '已连接：{n}——把此 IP 告诉另一台手机。'
    },
    'su_close': {
      'pt': 'Fechar mesa',
      'en': 'Close table',
      'es': 'Cerrar mesa',
      'zh': '关闭桌面'
    },
    'su_ip_hint': {
      'pt': 'IP ou IP:porta (ex. 192.168.0.10:40404)',
      'en': 'IP or IP:port (e.g. 192.168.0.10:40404)',
      'es': 'IP o IP:puerto (ej. 192.168.0.10:40404)',
      'zh': 'IP 或 IP:端口（例：192.168.0.10:40404）'
    },
    'su_connecting': {
      'pt': 'Conectando…',
      'en': 'Connecting…',
      'es': 'Conectando…',
      'zh': '连接中…'
    },
    'su_nonet': {
      'pt': 'Na mesma rede ({n})',
      'en': 'On the same network ({n})',
      'es': 'En la misma red ({n})',
      'zh': '同一网络（{n}）'
    },
    'su_noone': {
      'pt':
          'Ninguém encontrado ainda. Fiquem no mesmo Wi-Fi com a aba Jogar aberta.',
      'en': 'Nobody found yet. Stay on the same Wi-Fi with the Play tab open.',
      'es': 'Nadie aún. Quédense en el mismo Wi-Fi con Jugar abierto.',
      'zh': '暂未发现。请连同一 Wi-Fi 并打开对战页。'
    },
    'su_notable': {
      'pt': 'Sem mesa aberta',
      'en': 'No open table',
      'es': 'Sin mesa abierta',
      'zh': '没有开桌'
    },
    'su_table_open': {
      'pt': 'Mesa aberta • {n} jog.',
      'en': 'Open table • {n} players',
      'es': 'Mesa abierta • {n} jug.',
      'zh': '已开桌 • {n} 人'
    },
    'su_invite_title': {
      'pt': 'Convite de {n}',
      'en': 'Invite from {n}',
      'es': 'Invitación de {n}',
      'zh': '来自 {n} 的邀请'
    },
    'su_invite_body': {
      'pt': '{n} abriu uma mesa na mesma rede. Entrar?',
      'en': '{n} opened a table on the network. Join?',
      'es': '{n} abrió una mesa en la red. ¿Entrar?',
      'zh': '{n} 在局域网开了桌，加入吗？'
    },
    'su_leave_first': {
      'pt': 'Saia da partida atual primeiro.',
      'en': 'Leave the current match first.',
      'es': 'Sal de la partida actual primero.',
      'zh': '请先离开当前对局。'
    },
    'su_sent': {
      'pt': 'Convite enviado para {n}!',
      'en': 'Invite sent to {n}!',
      'es': '¡Invitación enviada a {n}!',
      'zh': '已向 {n} 发送邀请！'
    },
    'su_busy_invite': {
      'pt': '{n} te convidou, mas você já está em partida.',
      'en': '{n} invited you, but you are already in a match.',
      'es': '{n} te invitó, pero ya estás en partida.',
      'zh': '{n} 邀请了你，但你已在对局中。'
    },
    'su_history': {
      'pt': 'Histórico da partida',
      'en': 'Match history',
      'es': 'Historial de la partida',
      'zh': '对局历史'
    },
    'su_no_history': {
      'pt': 'Ainda não há ações registradas.',
      'en': 'No actions recorded yet.',
      'es': 'Aún no hay acciones registradas.',
      'zh': '暂无记录。'
    },
    'su_remove_title': {
      'pt': 'Remover {n} da mesa?',
      'en': 'Remove {n} from the table?',
      'es': '¿Quitar {n} de la mesa?',
      'zh': '将 {n} 移出桌面？'
    },
    'su_remove_body': {
      'pt': 'As fichas dele ficam na mesa como compartilhadas.',
      'en': 'Their tokens stay on the table as shared.',
      'es': 'Sus fichas quedan como compartidas.',
      'zh': '其衍生物将作为共享留在桌面。'
    },
    'su_ip_title': {
      'pt': 'IP do anfitrião',
      'en': 'Host IP',
      'es': 'IP del anfitrión',
      'zh': '主机 IP'
    },
    'su_continue': {
      'pt': 'Continuar',
      'en': 'Continue',
      'es': 'Continuar',
      'zh': '继续'
    },
    'su_th_midnight': {
      'pt': 'Meia-noite',
      'en': 'Midnight',
      'es': 'Medianoche',
      'zh': '午夜'
    },
    'su_th_forest': {
      'pt': 'Floresta',
      'en': 'Forest',
      'es': 'Bosque',
      'zh': '森林'
    },
    'su_th_arcane': {
      'pt': 'Arcano',
      'en': 'Arcane',
      'es': 'Arcano',
      'zh': '奥术'
    },
    'su_th_ember': {'pt': 'Brasa', 'en': 'Ember', 'es': 'Brasa', 'zh': '余烬'},
    'su_th_ocean': {
      'pt': 'Oceano',
      'en': 'Ocean',
      'es': 'Océano',
      'zh': '海洋'
    },
    'su_th_blood': {
      'pt': 'Sangue',
      'en': 'Blood',
      'es': 'Sangre',
      'zh': '鲜血'
    },
    'su_side_top': {'pt': 'Topo', 'en': 'Top', 'es': 'Arriba', 'zh': '上方'},
    'su_side_bottom': {
      'pt': 'Base',
      'en': 'Bottom',
      'es': 'Abajo',
      'zh': '下方'
    },
    'su_theme': {'pt': 'Tema', 'en': 'Theme', 'es': 'Tema', 'zh': '主题'},
    'su_bg': {
      'pt': 'Fundo',
      'en': 'Background',
      'es': 'Fondo',
      'zh': '背景'
    },
    'su_bg_none': {
      'pt': 'Sem imagem',
      'en': 'No image',
      'es': 'Sin imagen',
      'zh': '无图片'
    },
    'su_players_mode': {
      'pt': 'Jogadores',
      'en': 'Players',
      'es': 'Jugadores',
      'zh': '玩家'
    },
    'su_fmt_custom': {
      'pt': 'Personalizado',
      'en': 'Custom',
      'es': 'Personalizado',
      'zh': '自定义'
    },
    'su_cmd_multi': {
      'pt': 'Commander mesa',
      'en': 'Commander party',
      'es': 'Commander mesa',
      'zh': '多人指挥官'
    },
    'su_cmd_1v1': {
      'pt': 'Commander 1v1',
      'en': 'Commander 1v1',
      'es': 'Commander 1v1',
      'zh': '双人指挥官'
    },
    'su_effect': {
      'pt': 'Novo efeito',
      'en': 'New effect',
      'es': 'Nuevo efecto',
      'zh': '新效应'
    },
    'su_effect_name': {
      'pt': 'Nome (ex. Anthem, Fúria)',
      'en': 'Name (e.g. Anthem, Rage)',
      'es': 'Nombre (ej. Anthem, Furia)',
      'zh': '名称（例：Anthem、Fúria）'
    },
    'su_power': {
      'pt': 'Poder: ',
      'en': 'Power: ',
      'es': 'Fuerza: ',
      'zh': '攻击：'
    },
    'su_res': {'pt': 'Res: ', 'en': 'Tou: ', 'es': 'Res: ', 'zh': '防御：'},
    'su_power_full': {'pt': 'Poder', 'en': 'Power', 'es': 'Fuerza', 'zh': '攻击'},
    'su_res_full': {
      'pt': 'Resistência',
      'en': 'Toughness',
      'es': 'Resistencia',
      'zh': '防御'
    },
    'su_all_tokens': {
      'pt': 'Todas as fichas',
      'en': 'All tokens',
      'es': 'Todas las fichas',
      'zh': '所有衍生物'
    },
    'su_only': {'pt': 'Só: ', 'en': 'Only: ', 'es': 'Solo: ', 'zh': '仅：'},
    'su_eot': {
      'pt': 'Até o fim do turno',
      'en': 'Until end of turn',
      'es': 'Hasta el final del turno',
      'zh': '直到回合结束'
    },
    'su_mana_title': {
      'pt': 'Mana de qual cor?',
      'en': 'Which color of mana?',
      'es': '¿Maná de qué color?',
      'zh': '哪种颜色的法术力？'
    },
    'su_common_tokens': {
      'pt': 'Fichas comuns:',
      'en': 'Common tokens:',
      'es': 'Fichas comunes:',
      'zh': '常见衍生物：'
    },
    'su_add_count': {
      'pt': 'Adicionar: ',
      'en': 'Add: ',
      'es': 'Añadir: ',
      'zh': '添加：'
    },
    'su_qty_custom': {
      'pt': 'Quantidade personalizada',
      'en': 'Custom amount',
      'es': 'Cantidad personalizada',
      'zh': '自定义数量'
    },
    'su_how_many': {
      'pt': 'Aplicar a quantas da pilha? ({n} iguais)',
      'en': 'Apply to how many of the stack? ({n} same)',
      'es': '¿A cuántas de la pila? ({n} iguales)',
      'zh': '应用于这一叠中的几张？（{n} 张相同）'
    },
    'su_all_of': {
      'pt': 'Todas ({n})',
      'en': 'All ({n})',
      'es': 'Todas ({n})',
      'zh': '全部（{n}）'
    },
    'su_buff_t': {
      'pt': 'Bônus permanente',
      'en': 'Permanent buff',
      'es': 'Bonificación permanente',
      'zh': '永久加成'
    },
    'su_giant_t': {
      'pt': 'Bônus até o fim do turno',
      'en': 'Buff until end of turn',
      'es': 'Bonificación hasta el final',
      'zh': '回合结束前加成'
    },
    'su_add_more': {
      'pt': 'Adicionar mais {n}',
      'en': 'Add more {n}',
      'es': 'Añadir más {n}',
      'zh': '添加更多 {n}'
    },
    'su_mana_W': {'pt': 'branca', 'en': 'white', 'es': 'blanca', 'zh': '白色'},
    'su_mana_U': {'pt': 'azul', 'en': 'blue', 'es': 'azul', 'zh': '蓝色'},
    'su_mana_B': {'pt': 'preta', 'en': 'black', 'es': 'negra', 'zh': '黑色'},
    'su_mana_R': {'pt': 'vermelha', 'en': 'red', 'es': 'roja', 'zh': '红色'},
    'su_mana_G': {'pt': 'verde', 'en': 'green', 'es': 'verde', 'zh': '绿色'},
    'su_mana_C': {
      'pt': 'incolor',
      'en': 'colorless',
      'es': 'incolora',
      'zh': '无色'
    },
    'rs_treasure': {
      'pt': 'Sacrificar e gerar mana',
      'en': 'Sacrifice and add mana',
      'es': 'Sacrificar y generar maná',
      'zh': '牺牲并产生法术力'
    },
    'rs_food': {
      'pt': 'Sacrificar e ganhar 3 de vida',
      'en': 'Sacrifice and gain 3 life',
      'es': 'Sacrificar y ganar 3 vidas',
      'zh': '牺牲并获得 3 点生命'
    },
    'rs_clue': {
      'pt': 'Sacrificar Pista',
      'en': 'Sacrifice Clue',
      'es': 'Sacrificar Pista',
      'zh': '牺牲线索'
    },
    'rs_blood': {
      'pt': 'Sacrificar Sangue',
      'en': 'Sacrifice Blood',
      'es': 'Sacrificar Sangre',
      'zh': '牺牲鲜血'
    },
    'rs_map': {
      'pt': 'Sacrificar Mapa',
      'en': 'Sacrifice Map',
      'es': 'Sacrificar Mapa',
      'zh': '牺牲地图'
    },
    'rs_powerstone': {
      'pt': 'Virar e gerar {C}',
      'en': 'Tap and add {C}',
      'es': 'Girar y generar {C}',
      'zh': '横置并产生 {C}'
    },
    'rs_resolve': {
      'pt': 'Resolver',
      'en': 'Resolve',
      'es': 'Resolver',
      'zh': '结算'
    },
    'rsx_treasure': {
      'pt':
          'A ficha será sacrificada e uma mana da cor escolhida entrará no contador de mana.',
      'en':
          'The token is sacrificed and one mana of the chosen color is added.',
      'es': 'La ficha se sacrifica y entra un maná del color elegido.',
      'zh': '牺牲该衍生物，获得一点所选颜色的法术力。'
    },
    'rsx_food': {
      'pt': 'A ficha será sacrificada e o dono ganhará 3 pontos de vida.',
      'en': 'The token is sacrificed and its owner gains 3 life.',
      'es': 'La ficha se sacrifica y su dueño gana 3 vidas.',
      'zh': '牺牲该衍生物，其操控者获得 3 点生命。'
    },
    'rsx_clue': {
      'pt':
          'A ficha será sacrificada. Lembre-se de pagar {2} e comprar um card.',
      'en': 'The token is sacrificed. Remember to pay {2} and draw a card.',
      'es': 'La ficha se sacrifica. Recuerda pagar {2} y robar.',
      'zh': '牺牲该衍生物。记得支付 {2} 并抓一张牌。'
    },
    'rsx_blood': {
      'pt':
          'A ficha será sacrificada. Lembre-se de pagar {1}, virar, descartar um card e comprar um card.',
      'en':
          'The token is sacrificed. Remember to pay {1}, tap, discard and draw.',
      'es':
          'La ficha se sacrifica. Recuerda pagar {1}, girar, descartar y robar.',
      'zh': '牺牲该衍生物。记得支付 {1}、横置、弃牌并抓牌。'
    },
    'rsx_map': {
      'pt':
          'A ficha será sacrificada. Lembre-se de pagar {1} e explorar com a criatura alvo.',
      'en': 'The token is sacrificed. Remember to pay {1} and explore.',
      'es': 'La ficha se sacrifica. Recuerda pagar {1} y explorar.',
      'zh': '牺牲该衍生物。记得支付 {1} 并探查。'
    },
    'rsx_powerstone': {
      'pt':
          'A ficha será virada e {C} entrará no contador de mana. Essa mana tem a restrição da Pedra de poder.',
      'en': 'The token is tapped for {C} with the Powerstone restriction.',
      'es': 'La ficha se gira para {C} con la restricción de la Piedra.',
      'zh': '横置该衍生物产生 {C}（受动力石限制）。'
    },
    'su_died': {
      'pt': 'Você morreu! 💀',
      'en': 'You died! 💀',
      'es': '¡Moriste! 💀',
      'zh': '你输了！💀'
    },
    'su_won': {
      'pt': 'Você venceu! 🏆',
      'en': 'You won! 🏆',
      'es': '¡Ganaste! 🏆',
      'zh': '你赢了！🏆'
    },
    'su_x_won': {
      'pt': '{n} venceu! 🏆',
      'en': '{n} won! 🏆',
      'es': '¡{n} ganó! 🏆',
      'zh': '{n} 获胜！🏆'
    },
    'su_x_died': {
      'pt': '💀 {n} morreu!',
      'en': '💀 {n} died!',
      'es': '¡💀 {n} murió!',
      'zh': '💀 {n} 出局！'
    },
    'su_died_msg': {
      'pt': '{w} venceu a partida.',
      'en': '{w} won the match.',
      'es': '{w} ganó la partida.',
      'zh': '{w} 赢得了对局。'
    },
    'su_life_msg': {
      'pt': '{n} chegou a {l} de vida.',
      'en': '{n} reached {l} life.',
      'es': '{n} llegó a {l} vidas.',
      'zh': '{n} 生命变为 {l}。'
    },
    // ---------- Mesa: toolbar ----------
    'play_turn': {'pt': 'Vez', 'en': 'Turn', 'es': 'Turno', 'zh': '行动'},
    'play_round': {'pt': 'Rodada', 'en': 'Round', 'es': 'Ronda', 'zh': '回合'},
    'play_focus': {
      'pt': 'Modo foco',
      'en': 'Focus mode',
      'es': 'Modo foco',
      'zh': '专注模式'
    },
    'play_exit_focus': {
      'pt': 'Sair do modo foco',
      'en': 'Exit focus mode',
      'es': 'Salir del modo foco',
      'zh': '退出专注模式'
    },
    'play_history': {
      'pt': 'Histórico',
      'en': 'History',
      'es': 'Historial',
      'zh': '历史'
    },
    'play_undo': {
      'pt': 'Desfazer última ação',
      'en': 'Undo last action',
      'es': 'Deshacer última acción',
      'zh': '撤销上一步'
    },
    // ---------- Mesa: seções ----------
    'play_my_table': {
      'pt': 'SUA MESA',
      'en': 'YOUR TABLE',
      'es': 'TU MESA',
      'zh': '你的桌面'
    },
    'play_my_tokens': {
      'pt': 'Suas cartas',
      'en': 'Your cards',
      'es': 'Tus cartas',
      'zh': '你的牌'
    },
    'play_opp_tokens': {
      'pt': 'Cartas de',
      'en': 'Cards of',
      'es': 'Cartas de',
      'zh': '的牌'
    },
    'play_shared': {
      'pt': 'Mesa (compartilhadas)',
      'en': 'Table (shared)',
      'es': 'Mesa (compartidas)',
      'zh': '桌面（共享）'
    },
    'play_no_tokens': {
      'pt': 'Nenhuma carta sua.\nToque em + para criar.',
      'en': 'No cards yet.\nTap + to create.',
      'es': 'Sin cartas.\nToca + para crear.',
      'zh': '还没有牌。\n点 + 创建。'
    },
    'play_no_tokens_short': {
      'pt': 'Sem cartas',
      'en': 'No cards',
      'es': 'Sin cartas',
      'zh': '无牌'
    },
    'play_tokens_count': {
      'pt': 'cartas',
      'en': 'cards',
      'es': 'cartas',
      'zh': '牌'
    },
    'play_add_token': {
      'pt': 'Adicionar ficha',
      'en': 'Add token',
      'es': 'Añadir ficha',
      'zh': '添加衍生物'
    },
    'play_new_effect': {
      'pt': 'Novo efeito',
      'en': 'New effect',
      'es': 'Nuevo efecto',
      'zh': '新效应'
    },
    // ---------- Menu da ficha ----------
    'token_edit': {
      'pt': 'Editar dados',
      'en': 'Edit details',
      'es': 'Editar datos',
      'zh': '编辑信息'
    },
    'token_resolve_sub': {
      'pt': 'Resolver a habilidade da ficha',
      'en': "Resolve the token's ability",
      'es': 'Resolver la habilidad',
      'zh': '结算异能'
    },
    'token_more': {
      'pt': 'Adicionar mais fichas iguais',
      'en': 'Add more of the same',
      'es': 'Añadir más iguales',
      'zh': '添加更多相同的'
    },
    'token_more_sub': {
      'pt': 'Escolha 1, 2, 5, 10 ou uma quantidade',
      'en': 'Pick 1, 2, 5, 10 or a custom amount',
      'es': 'Elige 1, 2, 5, 10 o una cantidad',
      'zh': '选择数量'
    },
    'token_buff': {
      'pt': 'Bônus permanente…',
      'en': 'Permanent buff…',
      'es': 'Bonificación permanente…',
      'zh': '永久加成…'
    },
    'token_buff_sub': {
      'pt': 'Valor e quantidade de fichas',
      'en': 'Value and token count',
      'es': 'Valor y cantidad',
      'zh': '数值和数量'
    },
    'token_giant': {
      'pt': 'Bônus até o fim do turno…',
      'en': 'Buff until end of turn…',
      'es': 'Bonificación hasta el final…',
      'zh': '回合结束前加成…'
    },
    'token_giant_sub': {
      'pt': 'Valor e quantidade de fichas',
      'en': 'Value and token count',
      'es': 'Valor y cantidad',
      'zh': '数值和数量'
    },
    'token_art': {
      'pt': 'Buscar arte da ficha',
      'en': 'Find token art',
      'es': 'Buscar arte',
      'zh': '搜索插画'
    },
    'token_hide': {
      'pt': 'Ocultar nome da ficha',
      'en': 'Hide name on stack',
      'es': 'Ocultar nombre de la pila',
      'zh': '隐藏这一叠的名称'
    },
    'token_show': {
      'pt': 'Mostrar nome na ficha',
      'en': 'Show name on stack',
      'es': 'Mostrar nombre de la pila',
      'zh': '显示这一叠的名称'
    },
    'token_hide_sub': {
      'pt': 'Vale para a pilha inteira',
      'en': 'Applies to the whole stack',
      'es': 'Vale para toda la pila',
      'zh': '应用于整叠'
    },
    'token_tap': {'pt': 'Virar', 'en': 'Tap', 'es': 'Girar', 'zh': '横置'},
    'token_untap': {
      'pt': 'Desvirar',
      'en': 'Untap',
      'es': 'Enderezar',
      'zh': '重置'
    },
    'token_remove': {
      'pt': 'Remover',
      'en': 'Remove',
      'es': 'Eliminar',
      'zh': '移除'
    },
    'token_tapped': {
      'pt': 'VIRADA',
      'en': 'TAPPED',
      'es': 'GIRADA',
      'zh': '已横置'
    },
    'tok_now_tapped': {
      'pt': '{n} virada',
      'en': '{n} tapped',
      'es': '{n} girada',
      'zh': '{n}已横置'
    },
    'tok_now_untapped': {
      'pt': '{n} desvirada',
      'en': '{n} untapped',
      'es': '{n} enderezada',
      'zh': '{n}已重置'
    },
    'tok_many_tapped': {
      'pt': '{q}× {n} viradas',
      'en': '{q}× {n} tapped',
      'es': '{q}× {n} giradas',
      'zh': '{q}× {n}已横置'
    },
    'tok_many_untapped': {
      'pt': '{q}× {n} desviradas',
      'en': '{q}× {n} untapped',
      'es': '{q}× {n} enderezadas',
      'zh': '{q}× {n}已重置'
    },
    // ---------- Vida ----------
    'life_title': {
      'pt': 'Ajustar vida',
      'en': 'Adjust life',
      'es': 'Ajustar vidas',
      'zh': '调整生命'
    },
    'life_custom': {
      'pt': 'Valor personalizado (+ ou -)',
      'en': 'Custom value (+ or -)',
      'es': 'Valor personalizado (+ o -)',
      'zh': '自定义数值（+ 或 -）'
    },
    'life_reset': {
      'pt': 'Voltar à vida inicial',
      'en': 'Reset to starting life',
      'es': 'Volver a la vida inicial',
      'zh': '恢复初始生命'
    },
    // ---------- Arte ----------
    'art_choose': {
      'pt': 'Escolha a arte para',
      'en': 'Choose art for',
      'es': 'Elige el arte de',
      'zh': '选择插画：'
    },
    'art_scope': {
      'pt':
          'Vale para todas com esse nome — suas e do oponente — inclusive as próximas.',
      'en':
          'Applies to all with this name — yours and the opponent\'s — including new ones.',
      'es':
          'Vale para todas con ese nombre — tuyas y del rival — incluso las próximas.',
      'zh': '适用于所有同名衍生物（双方），包括新创建的。'
    },
    'art_lang': {
      'pt': 'Idioma da arte',
      'en': 'Art language',
      'es': 'Idioma del arte',
      'zh': '插画语言'
    },
    'art_all': {'pt': 'Todos', 'en': 'All', 'es': 'Todos', 'zh': '全部'},
    'art_empty': {
      'pt': 'Nada encontrado.',
      'en': 'Nothing found.',
      'es': 'Nada encontrado.',
      'zh': '没有找到。'
    },
    'art_maintenance': {
      'pt': 'Scryfall em manutenção. Tente de novo em alguns minutos.',
      'en': 'Scryfall is under maintenance. Try again in a few minutes.',
      'es': 'Scryfall en mantenimiento. Intenta de nuevo en unos minutos.',
      'zh': 'Scryfall 正在维护，请几分钟后再试。'
    },
    'art_error': {
      'pt': 'Falha ao buscar arte. Verifique a internet e tente de novo.',
      'en': 'Failed to fetch art. Check connection and retry.',
      'es': 'Error al buscar el arte. Revisa la conexión.',
      'zh': '获取插画失败，请检查网络后重试。'
    },
    // ---------- Reconexão ----------
    'lan_lost': {
      'pt': 'Conexão perdida — partida salva',
      'en': 'Connection lost — match saved',
      'es': 'Conexión perdida — partida guardada',
      'zh': '连接丢失——对局已保存'
    },
    'lan_reopen': {
      'pt': 'Reabrir minha mesa',
      'en': 'Reopen my table',
      'es': 'Reabrir mi mesa',
      'zh': '重新开桌'
    },
    'lan_reconnect': {
      'pt': 'Reconectar',
      'en': 'Reconnect',
      'es': 'Reconectar',
      'zh': '重新连接'
    },
    'lan_change_ip': {
      'pt': 'Trocar IP',
      'en': 'Change IP',
      'es': 'Cambiar IP',
      'zh': '更换 IP'
    },
    // ---------- Diálogos de ficha ----------
    'dlg_new_token': {
      'pt': 'Nova ficha',
      'en': 'New token',
      'es': 'Nueva ficha',
      'zh': '新衍生物'
    },
    'dlg_edit_token': {
      'pt': 'Editar ficha',
      'en': 'Edit token',
      'es': 'Editar ficha',
      'zh': '编辑衍生物'
    },
    'dlg_name': {
      'pt': 'Nome (ex. Soldado)',
      'en': 'Name (e.g. Soldier)',
      'es': 'Nombre (ej. Soldado)',
      'zh': '名称（例：士兵）'
    },
    'token_counters': {
      'pt': 'Marcadores…',
      'en': 'Counters…',
      'es': 'Contadores…',
      'zh': '指示物…'
    },
    'token_counters_sub': {
      'pt': '+1/+1, lealdade e carga',
      'en': '+1/+1, loyalty and charge',
      'es': 'Lealtad y carga',
      'zh': '+1/+1、忠诚和充能'
    },
    'token_counters_title': {
      'pt': 'Marcadores de',
      'en': 'Counters on',
      'es': 'Contadores de',
      'zh': '指示物：'
    },
    'token_counters_pt': {
      'pt': 'Entram no P/T',
      'en': 'Count toward P/T',
      'es': 'Cuentan para F/R',
      'zh': '计入攻防'
    },
    'token_counters_seal': {
      'pt': 'Só selo, não mexe no P/T',
      'en': 'Badge only, no P/T change',
      'es': 'Solo marca, sin cambiar F/R',
      'zh': '仅标记，不影响攻防'
    },
    'token_loyalty': {
      'pt': 'Lealdade',
      'en': 'Loyalty',
      'es': 'Lealtad',
      'zh': '忠诚'
    },
    'token_charge': {'pt': 'Carga', 'en': 'Charge', 'es': 'Carga', 'zh': '充能'},
    'mk_minus': {'pt': '-1/-1', 'en': '-1/-1', 'es': '-1/-1', 'zh': '-1/-1'},
    'mk_minus_sub': {
      'pt': 'Reduzem o P/T (anulam +1/+1 em pares)',
      'en': 'Reduce P/T (cancel +1/+1 in pairs)',
      'es': 'Reducen F/R (anulan +1/+1 en pares)',
      'zh': '降低攻防（与 +1/+1 成对抵消）'
    },
    'mk_custom': {
      'pt': 'Personalizados',
      'en': 'Custom',
      'es': 'Personalizados',
      'zh': '自定义'
    },
    'mk_empty': {
      'pt': 'Nenhum. Toque abaixo para criar.',
      'en': 'None yet. Tap below to create.',
      'es': 'Ninguno. Toca abajo para crear.',
      'zh': '暂无，点击下方创建。'
    },
    'mk_new': {
      'pt': 'Novo marcador',
      'en': 'New counter',
      'es': 'Nuevo contador',
      'zh': '新指示物'
    },
    'mk_name': {
      'pt': 'Nome (ex. Escudo)',
      'en': 'Name (e.g. Shield)',
      'es': 'Nombre (ej. Escudo)',
      'zh': '名称（例：护盾）'
    },
    'mk_count': {
      'pt': 'Quantidade',
      'en': 'Amount',
      'es': 'Cantidad',
      'zh': '数量'
    },
    'mk_perm': {
      'pt': 'Permanente',
      'en': 'Permanent',
      'es': 'Permanente',
      'zh': '永久'
    },
    'mk_eot': {
      'pt': 'Até o fim do turno',
      'en': 'Until end of turn',
      'es': 'Hasta el final del turno',
      'zh': '直到回合结束'
    },
    'token_custom': {
      'pt': 'Personalizada…',
      'en': 'Custom…',
      'es': 'Personalizada…',
      'zh': '自定义…'
    },
    'token_card': {
      'pt': 'Buscar carta…',
      'en': 'Find a card…',
      'es': 'Buscar carta…',
      'zh': '搜索牌…'
    },
    'card_title': {
      'pt': 'Colocar carta na mesa',
      'en': 'Put a card on the table',
      'es': 'Poner carta en la mesa',
      'zh': '将牌放到桌面'
    },
    'card_hint': {
      'pt': 'Nome da carta…',
      'en': 'Card name…',
      'es': 'Nombre de la carta…',
      'zh': '牌名…'
    },
    'card_local': {
      'pt': 'Na sua coleção',
      'en': 'In your collection',
      'es': 'En tu colección',
      'zh': '在你的收藏中'
    },
    'card_remote_btn': {
      'pt': 'Buscar no Scryfall',
      'en': 'Search Scryfall',
      'es': 'Buscar en Scryfall',
      'zh': '在 Scryfall 搜索'
    },
    'card_remote': {
      'pt': 'No Scryfall',
      'en': 'On Scryfall',
      'es': 'En Scryfall',
      'zh': 'Scryfall 结果'
    },
    'card_start': {
      'pt': 'Digite para buscar na coleção. Se não tiver, busque no Scryfall.',
      'en': 'Type to search your collection. Otherwise, try Scryfall.',
      'es': 'Escribe para buscar en tu colección o en Scryfall.',
      'zh': '输入以搜索收藏，没有则试试 Scryfall。'
    },
    'dlg_pt': {
      'pt': 'Poder/Resistência (ex. 2/2)',
      'en': 'Power/Toughness (e.g. 2/2)',
      'es': 'Fuerza/Resistencia (ej. 2/2)',
      'zh': '攻击/防御（例：2/2）'
    },
    'dlg_desc': {
      'pt': 'Descrição/regras (ex. Voar)',
      'en': 'Description/rules (e.g. Flying)',
      'es': 'Descripción (ej. Vuela)',
      'zh': '描述/规则（例：飞行）'
    },
    'dlg_cost': {
      'pt': 'Custo (ex. 2GG ou X)',
      'en': 'Cost (e.g. 2GG or X)',
      'es': 'Coste (ej. 2GG o X)',
      'zh': '费用（例：2GG 或 X）'
    },
    'dlg_type': {
      'pt': 'Tipo',
      'en': 'Type',
      'es': 'Tipo',
      'zh': '类别'
    },
    'dlg_type_hint': {
      'pt': 'Criatura — Elfo',
      'en': 'Creature — Elf',
      'es': 'Criatura — Elfo',
      'zh': '生物 — 精灵'
    },
    'dlg_abilities': {
      'pt': 'Habilidades',
      'en': 'Abilities',
      'es': 'Habilidades',
      'zh': '异能'
    },
    'dlg_save_template': {
      'pt': 'Salvar modelo',
      'en': 'Save template',
      'es': 'Guardar modelo',
      'zh': '保存模板'
    },
    'dlg_template_saved': {
      'pt': 'Modelo salvo em Minhas cartas.',
      'en': 'Template saved under My cards.',
      'es': 'Modelo guardado en Mis cartas.',
      'zh': '模板已保存到“我的牌”。'
    },
    'dlg_name_needed': {
      'pt': 'Dê um nome antes de salvar.',
      'en': 'Name it before saving.',
      'es': 'Ponle nombre antes de guardar.',
      'zh': '保存前请先命名。'
    },
    'tpl_mine': {
      'pt': 'Minhas cartas',
      'en': 'My cards',
      'es': 'Mis cartas',
      'zh': '我的牌'
    },
    'ab_flying': {'pt': 'Voar', 'en': 'Flying', 'es': 'Vuela', 'zh': '飞行'},
    'ab_vigilance': {
      'pt': 'Vigilância',
      'en': 'Vigilance',
      'es': 'Vigilancia',
      'zh': '警戒'
    },
    'ab_lifelink': {
      'pt': 'Vínculo com a vida',
      'en': 'Lifelink',
      'es': 'Vínculo vital',
      'zh': '系命'
    },
    'ab_deathtouch': {
      'pt': 'Toque mortífero',
      'en': 'Deathtouch',
      'es': 'Toque mortal',
      'zh': '死触'
    },
    'ab_haste': {'pt': 'Ímpeto', 'en': 'Haste', 'es': 'Prisa', 'zh': '敏捷'},
    'ab_trample': {
      'pt': 'Atropelar',
      'en': 'Trample',
      'es': 'Arrolla',
      'zh': '践踏'
    },
    'ab_menace': {
      'pt': 'Ameaça',
      'en': 'Menace',
      'es': 'Amenaza',
      'zh': '威慑'
    },
    'ab_reach': {
      'pt': 'Alcance',
      'en': 'Reach',
      'es': 'Alcance',
      'zh': '延势'
    },
    'ab_first_strike': {
      'pt': 'Iniciativa',
      'en': 'First strike',
      'es': 'Daña primero',
      'zh': '先攻'
    },
    'ab_double_strike': {
      'pt': 'Golpe duplo',
      'en': 'Double strike',
      'es': 'Daña dos veces',
      'zh': '连击'
    },
    'ab_hexproof': {
      'pt': 'Hexproof',
      'en': 'Hexproof',
      'es': 'Antimaldición',
      'zh': '辟邪'
    },
    'ab_indestructible': {
      'pt': 'Indestrutível',
      'en': 'Indestructible',
      'es': 'Indestructible',
      'zh': '不灭'
    },
    'token_utility': {
      'pt': 'Utilitária',
      'en': 'Utility',
      'es': 'Utilidad',
      'zh': '功能牌'
    },
    'token_base': {'pt': 'base', 'en': 'base', 'es': 'base', 'zh': '基础'},
    'token_untapped': {
      'pt': 'Desvirada',
      'en': 'Untapped',
      'es': 'Enderezada',
      'zh': '未横置'
    },
    'token_options': {
      'pt': 'Opções',
      'en': 'Options',
      'es': 'Opciones',
      'zh': '选项'
    },
    'token_marker': {
      'pt': 'Criar marcador',
      'en': 'Create marker',
      'es': 'Crear marcador',
      'zh': '创建标记'
    },
    'token_marker_sub': {
      'pt': 'Global ou com esta ficha dentro',
      'en': 'Global or holding this card',
      'es': 'Global o con esta carta dentro',
      'zh': '全局或包含此牌'
    },
    'mk_title': {
      'pt': 'Marcador',
      'en': 'Marker',
      'es': 'Marcador',
      'zh': '标记'
    },
    'mk_name_hint': {
      'pt': 'Ex. Veneno, Energia, Tesouros',
      'en': 'E.g. Poison, Energy, Treasures',
      'es': 'Ej. Veneno, Energía, Tesoros',
      'zh': '例：中毒、能量、宝物'
    },
    'mk_global': {
      'pt': 'Global (vale p/ a mesa toda)',
      'en': 'Global (whole table)',
      'es': 'Global (toda la mesa)',
      'zh': '全局（整桌有效）'
    },
    'mk_global_sub': {
      'pt': 'Desmarque para colocar fichas dentro',
      'en': 'Uncheck to hold specific cards',
      'es': 'Desmarca para meter cartas dentro',
      'zh': '取消勾选以放入指定牌'
    },
    'mk_members': {
      'pt': 'Fichas dentro do marcador',
      'en': 'Cards inside the marker',
      'es': 'Cartas dentro del marcador',
      'zh': '标记内的牌'
    },
    'mk_scope_n': {
      'pt': '{n} ficha(s) dentro',
      'en': '{n} card(s) inside',
      'es': '{n} carta(s) dentro',
      'zh': '内含 {n} 张牌'
    },
    'mk_edit_members': {
      'pt': 'Editar fichas',
      'en': 'Edit cards',
      'es': 'Editar cartas',
      'zh': '编辑牌'
    },
    'mk_new_short': {
      'pt': 'Marcador',
      'en': 'Marker',
      'es': 'Marcador',
      'zh': '标记'
    },
    'mk_board': {
      'pt': 'Marcadores da mesa',
      'en': 'Table markers',
      'es': 'Marcadores de la mesa',
      'zh': '桌面标记'
    },
    'fr_code_dead': {
      'pt': 'Esse código expirou (a pessoa trocou de aparelho). Peça o código novo.',
      'en': 'That code expired (they switched devices). Ask for the new code.',
      'es': 'Ese código expiró (cambió de aparato). Pide el código nuevo.',
      'zh': '该代码已过期（对方更换了设备），请索取新代码。'
    },
    'mk_add': {
      'pt': 'Adicionar marcador…',
      'en': 'Add marker…',
      'es': 'Añadir marcador…',
      'zh': '添加标记…'
    },
    'mk_type': {
      'pt': 'Tipo de marcador',
      'en': 'Marker type',
      'es': 'Tipo de marcador',
      'zh': '标记类型'
    },
    'mk_kind_custom': {
      'pt': 'Contador',
      'en': 'Counter',
      'es': 'Contador',
      'zh': '计数'
    },
    'mk_kind_plus': {
      'pt': '+1/+1',
      'en': '+1/+1',
      'es': '+1/+1',
      'zh': '+1/+1'
    },
    'mk_kind_minus': {
      'pt': '−1/−1',
      'en': '-1/-1',
      'es': '-1/-1',
      'zh': '-1/-1'
    },
    'mk_custom_ex': {
      'pt': 'Ex.: Energia ×5 — só conta, não muda carta.',
      'en': 'E.g. Energy ×5 — counts only, changes no card.',
      'es': 'Ej. Energía ×5 — solo cuenta, no cambia cartas.',
      'zh': '例：能量 ×5——仅计数，不改变牌。'
    },
    'mk_plus_ex': {
      'pt': 'Ex.: +2 em {n} — carimba +1/+1 de verdade.',
      'en': 'E.g. +2 on {n} — stamps real +1/+1.',
      'es': 'Ej. +2 en {n} — pone +1/+1 de verdad.',
      'zh': '例：{n} +2——放置真实 +1/+1。'
    },
    'mk_minus_ex': {
      'pt': 'Ex.: +2 em {n} — carimba −1/−1 de verdade.',
      'en': 'E.g. +2 on {n} — stamps real -1/-1.',
      'es': 'Ej. +2 en {n} — pone -1/-1 de verdad.',
      'zh': '例：{n} +2——放置真实 -1/-1。'
    },
    'mk_plus_name': {
      'pt': 'Marcador +1/+1',
      'en': '+1/+1 marker',
      'es': 'Marcador +1/+1',
      'zh': '+1/+1 标记'
    },
    'mk_minus_name': {
      'pt': 'Marcador −1/−1',
      'en': '-1/-1 marker',
      'es': 'Marcador -1/-1',
      'zh': '-1/-1 标记'
    },
    'mk_custom_name': {
      'pt': 'Contador',
      'en': 'Counter',
      'es': 'Contador',
      'zh': '计数'
    },
    'mk_stamp_where': {
      'pt': 'Carimbar em quais cartas?',
      'en': 'Stamp on which cards?',
      'es': '¿Poner en qué cartas?',
      'zh': '放置到哪些牌上？'
    },
    'mk_quick_custom': {
      'pt': 'Contador',
      'en': 'Counter',
      'es': 'Contador',
      'zh': '计数'
    },
    'mk_quick_plus': {
      'pt': '+1/+1',
      'en': '+1/+1',
      'es': '+1/+1',
      'zh': '+1/+1'
    },
    'mk_quick_minus': {
      'pt': '−1/−1',
      'en': '-1/-1',
      'es': '-1/-1',
      'zh': '-1/-1'
    },
    'ocr_title': {
      'pt': 'Escanear carta',
      'en': 'Scan card',
      'es': 'Escanear carta',
      'zh': '扫描牌'
    },
    'ocr_hint': {
      'pt': 'Enquadre o nome no retângulo e fotografe.',
      'en': 'Frame the name and shoot.',
      'es': 'Encuadra el nombre y fotografía.',
      'zh': '将名称框入矩形后拍照。'
    },
    'ocr_pick': {
      'pt': 'Toque no nome certo:',
      'en': 'Tap the right name:',
      'es': 'Toca el nombre correcto:',
      'zh': '点击正确的名称：'
    },
    'ocr_noread': {
      'pt': 'Não li nada. Aproxime e tente de novo.',
      'en': 'Nothing read. Get closer and retry.',
      'es': 'No leí nada. Acércate e inténtalo.',
      'zh': '未能识别，靠近后重试。'
    },
    'ocr_fail': {
      'pt': 'Falha na leitura.',
      'en': 'Read failed.',
      'es': 'Falló la lectura.',
      'zh': '识别失败。'
    },
    'life_poison': {
      'pt': 'Veneno (10+ mata)',
      'en': 'Poison (10+ kills)',
      'es': 'Veneno (10+ mata)',
      'zh': '中毒（10+ 致死）'
    },
    'life_commander': {
      'pt': 'Dano de comandante',
      'en': 'Commander damage',
      'es': 'Daño de comandante',
      'zh': '指挥官伤害'
    },
    'life_commander_sub': {
      'pt': '21+ do mesmo comandante elimina',
      'en': '21+ from one commander eliminates',
      'es': '21+ del mismo comandante elimina',
      'zh': '同一指挥官 21+ 点即淘汰'
    },
    'life_counters': {
      'pt': 'Contadores do jogador',
      'en': 'Player counters',
      'es': 'Contadores del jugador',
      'zh': '玩家指示物'
    },
    'life_counter_hint': {
      'pt': 'Novo (ex. Energia)',
      'en': 'New (e.g. Energy)',
      'es': 'Nuevo (ej. Energía)',
      'zh': '新建（例：能量）'
    },
    'life_moved': {
      'pt': 'Vida {a} → {b}',
      'en': 'Life {a} → {b}',
      'es': 'Vidas {a} → {b}',
      'zh': '生命 {a} → {b}'
    },
    'art_pow': {'pt': 'P', 'en': 'P', 'es': 'F', 'zh': '攻'},
    'art_tou': {'pt': 'R', 'en': 'T', 'es': 'R', 'zh': '防'},
    'art_filter': {
      'pt': 'Filtrar (P/R e habilidades)',
      'en': 'Filter (P/T and abilities)',
      'es': 'Filtrar (F/R y habilidades)',
      'zh': '筛选（攻防和异能）'
    },
    'death_poison': {
      'pt': '{n} morreu de veneno (10+)!',
      'en': '{n} died of poison (10+)!',
      'es': '¡{n} murió por veneno (10+)!',
      'zh': '{n} 因中毒（10+）而死！'
    },
    'death_commander': {
      'pt': '{n} morreu para o comandante de {c} (21+)!',
      'en': '{n} died to {c}\'s commander (21+)!',
      'es': '¡{n} murió ante el comandante de {c} (21+)!',
      'zh': '{n} 死于 {c} 的指挥官（21+）！'
    },
    'settings_keywords': {
      'pt': 'Habilidades na carta',
      'en': 'Abilities on the card',
      'es': 'Habilidades en la carta',
      'zh': '牌上的异能'
    },
    'settings_keywords_sub': {
      'pt': 'Abaixo do nome ou no centro (como a descrição)',
      'en': 'Below the name or centered (like the description)',
      'es': 'Debajo del nombre o en el centro (como la descripción)',
      'zh': '名称下方或居中（像描述一样）'
    },
    'settings_kw_below': {
      'pt': 'Abaixo do nome',
      'en': 'Below the name',
      'es': 'Debajo del nombre',
      'zh': '名称下方'
    },
    'settings_kw_center': {
      'pt': 'No centro',
      'en': 'Centered',
      'es': 'En el centro',
      'zh': '居中'
    },
  };
}
