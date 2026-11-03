"""What the window's pages hold: the setup step or the box's list, its rows and thumbnails, the device tiles a drop
goes to, and Add Device."""
import os

from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk, Pango

import look
from ferry import cli, desktop
from widgets import background, button, ICONS, label, menu_popover, qr_texture


class PagesMixin:
    """Window's pages, drawn from the server's listing (self.data)."""

    def render(self):
        data = self.data
        step = self.step() if data else None
        items = look.received((data or {}).get("items") or [])
        waiting = look.waiting((data or {}).get("waiting"))   # sends to a computer that is asleep, above the received
        main = self.page == "main"

        # The section's title
        if self.page == "add":
            title = "ADD DEVICE"
        elif self.page == "devices":
            title = "DEVICES"
        elif self.page == "offer":
            title = "SEND TO"
        elif step or not data:
            title = "FERRY"
        elif self.dragging:
            title = "DROP TO SEND"
        else:
            title = "WAITING" if waiting else "RECEIVED"   # the received ones get a heading of their own below
        self.section.set_label(title)
        self.back.set_visible(not main)
        # The back button's own padding is the bar's margin: its chevron where the section's title starts elsewhere
        self.title_bar.set_margin_start(8 if main else 0)
        clearing = main and not step and not self.dragging and bool(items)
        # Clear is the received ones': under the sends that wait it sits on their heading, not beside WAITING
        self.clear_button.set_visible(clearing and not self.confirming and not waiting)
        for w in (self.question, self.clear_cancel, self.clear_yes):
            w.set_visible(clearing and self.confirming)
        self.question.set_label(look.clear_question(len(items)))

        # The page
        if self.page == "add":
            self.fill_add()
            self.stack.set_visible_child_name("add")
        elif self.page == "devices":
            self.devices_page.fill(data)
            self.stack.set_visible_child_name("devices")
        elif self.page == "offer" or (self.dragging and not step):
            self.fill_tiles()
            self.stack.set_visible_child_name("tiles")
        elif not data:
            self.show_step({"step": "not-published", "title": "Looking for Tailscale…", "text": ""}, spinner=True)
        elif step:
            self.show_step(step)
        elif items or waiting:
            self.fill_list(waiting + ([look.RECEIVED_HEADING] if waiting and items else []) + items)
            self.stack.set_visible_child_name("list")
        else:
            self.stack.set_visible_child_name("empty")

        # The update
        self.banner.set_visible(bool(self.update) or bool(self.update_error) or self.updating)
        if self.updating:
            self.banner_text.set_label(f"Updating to Ferry {self.update['version']}…")
        elif self.update_error:
            self.banner_text.set_label(self.update_error)
        elif self.update:
            self.banner_text.set_label(f"Ferry {self.update['version']} is out.")
        self.banner_button.set_visible(bool(self.update) and not self.updating)
        self.banner_button.set_label("Try Again" if self.update_error else "Update")

        # Sending
        devices = (data or {}).get("devices") or []
        target = next((d for d in devices if d["id"] == (data or {}).get("target")), None)
        self.pill_dot.set_visible(bool(target))
        if target:
            self.pill_name.set_label(target["name"])
            self.pill_name.remove_css_class("dim")
            if target.get("online"):
                self.pill_dot.remove_css_class("away")
            else:
                self.pill_dot.add_css_class("away")
            self.pill.set_tooltip_text(f"Send to {target['name']}: change device")
        else:
            self.pill_name.set_label("No devices yet")
            self.pill_name.add_css_class("dim")
            self.pill.set_tooltip_text("Add a device")
        busy = self.send_state[0] == "sending"
        blocked = bool(step) or not data
        for w in (self.pill, self.aa, self.plus):
            w.set_sensitive(not busy and not blocked)
        self.clip.set_sensitive(not busy and not blocked)
        state = self.send_state
        self.clip_label.set_label({"idle": "Send Clipboard", "sending": "Sending…", "nothing": "Nothing on the clipboard",
                                   "failed": "Try Again"}.get(state[0]) or
                                  (f"Waiting for {state[1]}" if state[0] == "waiting" else f"Sent to {state[1]} ✓"))
        self.clip_icon.set_visible(state[0] not in ("sent", "waiting"))
        self.clip_icon._icon = ("refresh-cw" if state[0] == "failed" else "clipboard-paste", "on_primary", 16, 2.0)
        self.clip_icon.set_from_paintable(ICONS.get(*self.clip_icon._icon))
        self.error.set_visible(state[0] == "failed")
        if state[0] == "failed":
            self.error.set_label(state[1])

    def show_step(self, step, spinner=False):
        box = self.step_box
        self.stack.set_visible_child_name("setup")
        if self.unchanged("setup", (step, self.note, self.acting, spinner)):
            return
        while box.get_first_child():
            box.remove(box.get_first_child())
        box.append(ICONS.image(look.STEP_ICONS.get(step["step"], "triangle-alert"), "accent", 30, 1.6))
        box.append(label(step["title"], "title-step", xalign=0.5, wrap=True))
        if step.get("text"):
            box.append(label(step["text"], "dim", xalign=0.5, wrap=True, selectable=True))
        if self.note:
            box.append(label(self.note, "away", xalign=0.5, wrap=True, selectable=True))
        if step.get("command"):
            row = Gtk.Box(spacing=8)
            row.add_css_class("command")
            cmd = label(step["command"], "mono", selectable=True, wrap=True)
            cmd.set_hexpand(True)
            row.append(cmd)
            row.append(button(None, "copy", "small-circle", tooltip="Copy",
                              on=lambda c=step["command"]: background(lambda: desktop.copy_text(c))))
            box.append(row)
        buttons = Gtk.Box(spacing=8, halign=Gtk.Align.CENTER)
        buttons.set_margin_top(4)
        if step.get("link"):
            title = look.LINK_TITLES.get(step["step"], "Open in Browser")
            buttons.append(button(title, None, *(() if step.get("action") else ("primary",)),
                                  on=lambda u=step["link"]: self.open_uri(u)))
        action = step.get("action")
        if action and not (action == "publish" and step["step"] == "not-published"):
            buttons.append(button(look.ACTION_TITLES[action], None, "primary",
                                  on=lambda a=action: self.run_action(a)))
        if buttons.get_first_child():
            box.append(buttons)
        if spinner or self.acting or step["step"] == "not-published":
            sp = Gtk.Spinner()
            sp.start()
            box.append(sp)
        for b in self.walk(buttons):
            if isinstance(b, Gtk.Button):
                b.set_sensitive(not self.acting)

    def unchanged(self, page, what):
        """Whether the page already shows what: refreshes come every few seconds, and building a page again flickers
        and takes the focus away from its button."""
        if self.shown.get(page) == what:
            return True
        self.shown[page] = what
        return False

    def walk(self, w):
        child = w.get_first_child()
        while child:
            yield child
            yield from self.walk(child)
            child = child.get_next_sibling()

    def fill_list(self, items):
        ids = [i["id"] for i in items]
        if ids == [getattr(r, "item", {}).get("id") for r in self.list_rows()]:
            for item in items:   # only the ages move
                if item["id"] in self.rows:
                    self.rows[item["id"]][1].set_label(look.meta(item))
            return
        while self.list.get_first_child():
            self.list.remove(self.list.get_first_child())
        self.rows = {}
        for item in items:
            self.list.append(self.heading_row(item) if item is look.RECEIVED_HEADING else self.make_row(item))

    def list_rows(self):
        child = self.list.get_first_child()
        while child:
            yield child
            child = child.get_next_sibling()

    def heading_row(self, item):
        """RECEIVED under the sends that wait, which have the page's title, with the received ones' Clear."""
        row = Gtk.ListBoxRow(activatable=False, selectable=False)
        row.item = item
        bar = Gtk.Box(spacing=8, margin_top=10)
        heading = label("RECEIVED", "section")
        heading.set_halign(Gtk.Align.START)
        heading.set_hexpand(True)
        bar.append(heading)
        bar.append(button("Clear", None, "flat", on=lambda: self.ask_clear(True)))
        row.set_child(bar)
        return row

    def make_row(self, item):
        row = Gtk.ListBoxRow()
        row.item = item
        box = Gtk.Box(spacing=10)
        is_file = item.get("kind") == "file"

        tile = Gtk.Box(halign=Gtk.Align.START, valign=Gtk.Align.CENTER)
        tile.set_size_request(36, 36)
        tile.set_overflow(Gtk.Overflow.HIDDEN)   # a thumbnail's corners too
        tile.add_css_class("tile")
        icon = ICONS.image(look.item_icon(item), "accent", 16)
        icon.set_halign(Gtk.Align.CENTER)
        icon.set_valign(Gtk.Align.CENTER)
        icon.set_size_request(36, 36)
        tile.append(icon)
        box.append(tile)
        if look.is_image(item) and item.get("path") and not item.get("waiting"):
            self.thumbnail(item, tile)

        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2, valign=Gtk.Align.CENTER)
        text.set_hexpand(True)
        code = None if is_file else look.code(item.get("text"))
        title = label(code or (item.get("name") or "file" if is_file else look.oneline(item.get("text"))),
                      "code" if code else "item", ellipsize=True)
        title.set_max_width_chars(1)   # the row's width, not the text's, decides
        title.set_hexpand(True)
        row.title = title
        meta = label(look.meta(item), "meta", ellipsize=True)
        meta.set_max_width_chars(1)
        text.append(title)
        text.append(meta)
        box.append(text)

        if item.get("waiting"):   # it isn't here to open or copy, only to cancel
            row.set_activatable(False)
            action = button(None, "x", "small-circle", tooltip="Cancel", on=lambda: self.cancel_waiting(item))
        else:
            action = button(None, "external-link" if is_file else "copy", "small-circle",
                            tooltip="Open" if is_file else "Copy",
                            on=lambda: self.open_file(item) if is_file else self.copy(item, row))
        action.set_valign(Gtk.Align.CENTER)
        box.append(action)
        row.set_child(box)
        row.set_tooltip_text(None if is_file else (item.get("text") or "")[:400])
        self.rows[item["id"]] = (row, meta)
        if item.get("waiting"):
            return row

        menu_click = Gtk.GestureClick(button=Gdk.BUTTON_SECONDARY)
        menu_click.connect("pressed", lambda g, _n, x, y: self.row_menu(row, item, x, y))
        row.add_controller(menu_click)

        drag = Gtk.DragSource(actions=Gdk.DragAction.COPY)
        drag.connect("prepare", lambda *_: self.drag_out(item))
        drag.connect("drag-begin", lambda src, _d: src.set_icon(Gtk.WidgetPaintable.new(tile), 18, 18))
        row.add_controller(drag)
        return row

    def thumbnail(self, item, tile):
        def show(tex):
            if tex is None:
                return
            self.thumbs[item["id"]] = tex
            while tile.get_first_child():
                tile.remove(tile.get_first_child())
            pic = Gtk.Image.new_from_paintable(tex)
            pic.set_pixel_size(36)
            tile.append(pic)
        if item["id"] in self.thumbs:
            return show(self.thumbs[item["id"]])

        def make():
            """The image's middle square, at twice the tile's size for HiDPI."""
            pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(item["path"], 256, 256, True)   # not a whole photo in memory
            side = min(pb.get_width(), pb.get_height())
            square = pb.new_subpixbuf((pb.get_width() - side) // 2, (pb.get_height() - side) // 2, side, side)
            return Gdk.Texture.new_for_pixbuf(square.scale_simple(72, 72, GdkPixbuf.InterpType.BILINEAR))
        background(make, show)

    def row_menu(self, row, item, x, y):
        if item.get("kind") == "file":
            entries = [("Open", lambda: self.open_file(item)),
                       ("Show in Files", lambda: background(lambda: desktop.show_in_files(item["path"])))]
        else:
            entries = [("Copy", lambda: self.copy(item, row))]
            if look.link(item.get("text")):
                entries.append(("Open Link", lambda: self.open_uri(look.link(item["text"]))))
        entries += ["-", ("Remove", lambda: self.remove(item), "away")]
        pop = menu_popover(entries, row)
        rect = Gdk.Rectangle()
        rect.x, rect.y, rect.width, rect.height = int(x), int(y), 1, 1
        pop.set_pointing_to(rect)
        pop.connect("closed", lambda p: GLib.idle_add(p.unparent))
        pop.popup()

    def drag_out(self, item):
        """A file drags out into a file manager or another app; a text as text."""
        if item.get("kind") == "file":
            if not os.path.exists(item.get("path", "")):
                self.refresh()
                return None
            return Gdk.ContentProvider.new_for_value(Gdk.FileList.new_from_list([Gio.File.new_for_path(item["path"])]))
        return Gdk.ContentProvider.new_for_value(item.get("text") or "")

    def fill_tiles(self):
        self.offered_label.set_visible(self.page == "offer")
        if self.offered:
            size = sum(os.path.getsize(p) for p in self.offered if os.path.isfile(p))
            self.offered_label.set_label(f"{look.what(self.offered)} · {look.human(size)}")
        while self.tiles.get_first_child():
            self.tiles.remove(self.tiles.get_first_child())
        devices = look.tiles((self.data or {}).get("devices") or [])
        if not devices:
            self.tiles.append(label("No devices to send to yet: add one with Add Device.", "dim", xalign=0.5,
                                    wrap=True))
            return
        for d in devices:
            tile = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, valign=Gtk.Align.FILL)
            tile.add_css_class("device")
            inner = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, valign=Gtk.Align.CENTER, vexpand=True)
            inner.append(ICONS.image(look.device_icon(d), "accent", 26, 1.6))
            name = label(d["name"], "mono", xalign=0.5, ellipsize=True)
            name.set_max_width_chars(1)
            name.set_hexpand(True)
            inner.append(name)
            tile.append(inner)
            tile.set_size_request(-1, 96)
            open_ = look.can_take(d) and self.send_state[0] != "sending"
            if not open_:
                tile.add_css_class("closed")
            tile.set_tooltip_text(f"Send to {d['name']}")
            if open_:
                target = Gtk.DropTarget.new(Gdk.FileList, Gdk.DragAction.COPY)
                target.connect("enter", lambda *_ , t=tile: (t.add_css_class("over"), Gdk.DragAction.COPY)[1])
                target.connect("leave", lambda *_, t=tile: t.remove_css_class("over"))
                target.connect("drop", lambda _t, value, *_r, d=d: self.dropped(value, d))
                tile.add_controller(target)
                click = Gtk.GestureClick()
                click.connect("released", lambda *_, d=d: self.tile_clicked(d))
                tile.add_controller(click)
                tile.set_cursor(Gdk.Cursor.new_from_name("pointer"))
            self.tiles.append(tile)

    def fill_add(self):
        box = self.add_box
        address = (self.data or {}).get("url")
        if self.unchanged("add", address):
            return
        while box.get_first_child():
            box.remove(box.get_first_child())
        if not address:
            box.append(label("This computer has no address on your tailnet yet: Ferry's setup says what's missing.",
                             "dim", xalign=0.5, wrap=True))
            return
        qr = Gtk.Box(halign=Gtk.Align.CENTER)
        qr.add_css_class("qr")
        pic = Gtk.Picture()
        pic.set_size_request(200, 200)
        pic.set_can_shrink(False)
        qr.append(pic)
        box.append(qr)

        def made(tex):
            if tex:
                pic.set_paintable(tex)
            else:
                qr.set_visible(False)
        background(lambda: qr_texture(cli.add_link(address)), made)
        row = Gtk.Box(spacing=8, halign=Gtk.Align.CENTER)
        addr = label(address, "mono", "dim", selectable=True)
        addr.set_ellipsize(Pango.EllipsizeMode.MIDDLE)
        row.append(addr)
        copy = button("Copy", None, "pill")
        copy.connect("clicked", lambda b: (background(lambda: desktop.copy_text(address)), b.set_label("Copied"),
                                           GLib.timeout_add(1500, lambda: b.set_label("Copy") and False)))
        row.append(copy)
        box.append(row)
        box.append(label("Scan this with your iPhone's Camera, or in the Ferry app (Add a Computer). On another phone, "
                         "the camera opens a page that leads to this computer's Ferry page: add that to the Home Screen.",
                         "dim", xalign=0.5, wrap=True))
