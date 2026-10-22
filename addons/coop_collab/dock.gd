@tool
extends ScrollContainer

var plugin: EditorPlugin
var session: Node
var name_edit: LineEdit
var address_edit: LineEdit
var port_edit: SpinBox
var password_edit: LineEdit
var status_label: Label
var scene_label: Label
var conflict_button: Button
var journal: RichTextLabel
var body: VBoxContainer
var chat: RichTextLabel
var chat_input: LineEdit
var _messages: Array[String] = []
var _lines: Array[String] = []

func _ready():
	name = "MapTogether"
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(body)
	custom_minimum_size.x = 240
	body.add_theme_constant_override("separation", 6)
	_label(body, "MapTogether · проект у хоста")
	name_edit = _edit("Имя", OS.get_environment("USER").left(30))
	address_edit = _edit("IP хоста", "127.0.0.1")
	port_edit = SpinBox.new()
	port_edit.min_value = 1024
	port_edit.max_value = 65535
	port_edit.value = 25568
	port_edit.prefix = "TCP порт: "
	body.add_child(port_edit)
	password_edit = _edit("Пароль комнаты", "")
	password_edit.secret = true
	var connection = HBoxContainer.new()
	body.add_child(connection)
	_button(connection, "Создать", func(): plugin.host(int(port_edit.value), name_edit.text, password_edit.text))
	_button(connection, "Войти", func(): plugin.join(address_edit.text.strip_edges(), int(port_edit.value), name_edit.text, password_edit.text))
	_button(connection, "Выйти", func(): session.stop())
	status_label = _label(body, "")
	scene_label = _label(body, "")
	var autosave = CheckBox.new()
	autosave.text = "Автосохранение карты и скриптов"
	autosave.button_pressed = true
	autosave.toggled.connect(func(value): plugin.auto_save = value)
	body.add_child(autosave)
	_label(body, "Разные объекты карты объединяются у хоста. Пересекающиеся правки сохраняются как конфликт.")
	_button(body, "Сохранить и отправить", func(): plugin.save_and_send())
	_button(body, "Получить файлы хоста", func(): session.refresh_from_host())
	conflict_button = _button(body, "Конфликты (0)", _show_conflicts)
	var diagnostics = HBoxContainer.new()
	body.add_child(diagnostics)
	_button(diagnostics, "Вывод", func(): plugin.open_output())
	_button(diagnostics, "Журнал", func(): journal.visible = not journal.visible)
	journal = RichTextLabel.new()
	journal.custom_minimum_size.y = 150
	journal.selection_enabled = true
	journal.scroll_following = true
	journal.hide()
	body.add_child(journal)
	_label(body, "Чат")
	chat = RichTextLabel.new()
	chat.custom_minimum_size.y = 140
	chat.scroll_following = true
	chat.selection_enabled = true
	body.add_child(chat)
	chat_input = LineEdit.new()
	chat_input.placeholder_text = "Сообщение · Enter — отправить"
	chat_input.text_submitted.connect(func(text):
		if session.connected:
			session.send_chat(text)
			chat_input.clear()
	)
	body.add_child(chat_input)
	session.chat_message.connect(_chat_message)
	refresh()

func _label(parent: Node, text: String) -> Label:
	var label = Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label

func _edit(placeholder: String, value: String) -> LineEdit:
	var edit = LineEdit.new()
	edit.placeholder_text = placeholder
	edit.text = value
	body.add_child(edit)
	return edit

func _button(parent: Node, text: String, action: Callable) -> Button:
	var button = Button.new()
	button.text = text
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.pressed.connect(action)
	parent.add_child(button)
	return button

func refresh():
	if not is_instance_valid(status_label) or session.store == null: return
	status_label.text = session.status()
	var path = plugin.current_scene_path()
	var editors: Array = session.leases.get(path, [])
	var editor_names: Array[String] = []
	for identity in editors: editor_names.append(session.names.get(identity, identity))
	scene_label.text = path.get_file() + "\nВ сцене: " + (", ".join(editor_names) if not editor_names.is_empty() else "только локальная копия")
	conflict_button.text = "Конфликты (%d)" % session.store.conflicts.size()
	conflict_button.disabled = session.store.conflicts.is_empty()

func log_message(message: String):
	_lines.append(Time.get_time_string_from_system() + " " + message)
	if _lines.size() > 150: _lines.pop_front()
	if is_instance_valid(journal): journal.text = "\n".join(_lines)

func _chat_message(message: Dictionary):
	_messages.append("[%s] %s: %s" % [message.get("time", ""), message.get("author", "Developer"), message.get("text", "")])
	if _messages.size() > 100: _messages.pop_front()
	chat.text = "\n".join(_messages)

func _show_conflicts():
	var dialog = AcceptDialog.new()
	dialog.title = "Обе версии сохранены в .coop_collab/objects"
	dialog.ok_button_text = "Закрыть"
	var content = VBoxContainer.new()
	content.custom_minimum_size = Vector2(650, 270)
	dialog.add_child(content)
	var list = ItemList.new()
	list.custom_minimum_size.y = 140
	content.add_child(list)
	var paths = session.store.conflicts.keys()
	for path in paths: list.add_item(path)
	var details = _label(content, "Выберите файл. Обе версии останутся в истории после выбора.")
	list.item_selected.connect(func(index):
		var conflict = session.store.conflicts[paths[index]]
		details.text = paths[index] + "\n" + conflict.reason + "\nЛокальная версия: " + conflict.local_hash + "\nВходящая: " + conflict.incoming_hash
	)
	var actions = HBoxContainer.new()
	content.add_child(actions)
	for take_host in [false, true]:
		_button(actions, "Принять входящую" if take_host else "Оставить локальную", func():
			var selection = list.get_selected_items()
			if selection.is_empty(): return
			if plugin.resolve_conflict(paths[selection[0]], take_host):
				dialog.queue_free()
			else: details.text = "Версия не применена. Закройте изменённую сцену/скрипт или разрешите конфликт на хосте. Данные сохранены."
		)
	body.add_child(dialog)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.close_requested.connect(dialog.queue_free)
	dialog.popup_centered()
