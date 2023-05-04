# -*- coding: utf-8 -*-
# This file is part of Xpra.
# Copyright (C) 2011-2022 Antoine Martin <antoine@xpra.org>
# Xpra is released under the terms of the GNU GPL v2, or, at your option, any
# later version. See the file COPYING for details.

import os
import re

import gi
gi.require_version('Gtk', '3.0')  # @UndefinedVariable
gi.require_version("GdkPixbuf", "2.0")  # @UndefinedVariable
from gi.repository import Gtk, GdkPixbuf  # @UnresolvedImport

from xpra.util import envbool, repr_ellipsized
from xpra.os_util import OSX, bytestostr
from xpra.codecs.icon_util import INKSCAPE_RE
from xpra.gtk_common.gtk_util import (
    menuitem,
    get_pixbuf_from_data, scaled_image,
    )
from xpra.gtk_common.about import about, close_about
from xpra.platform.gui import get_icon_size
from xpra.platform.paths import get_icon_dir
from xpra.log import Logger

log = Logger("menu")

MENU_ICONS = envbool("XPRA_MENU_ICONS", True)
HIDE_DISABLED_MENU_ENTRIES = envbool("XPRA_HIDE_DISABLED_MENU_ENTRIES", False)


LOSSLESS = "Lossless"
QUALITY_OPTIONS_COMMON = {
                50      : "Average",
                30      : "Low",
                }
MIN_QUALITY_OPTIONS = QUALITY_OPTIONS_COMMON.copy()
MIN_QUALITY_OPTIONS.update({
    0 : "None",
    75  : "High",
    })
MIN_QUALITY_OPTIONS = dict(sorted(MIN_QUALITY_OPTIONS.items()))
QUALITY_OPTIONS = QUALITY_OPTIONS_COMMON.copy()
QUALITY_OPTIONS.update({
    0 : "Auto",
    1   : "Lowest",
    90  : "Best",
    100 : LOSSLESS,
    })
QUALITY_OPTIONS = dict(sorted(QUALITY_OPTIONS.items()))


SPEED_OPTIONS_COMMON = {
                70      : "Low Latency",
                50      : "Average",
                30      : "Low Bandwidth",
                }
MIN_SPEED_OPTIONS = SPEED_OPTIONS_COMMON.copy()
MIN_SPEED_OPTIONS[0] = "None"
MIN_SPEED_OPTIONS = dict(sorted(MIN_SPEED_OPTIONS.items()))
SPEED_OPTIONS = SPEED_OPTIONS_COMMON.copy()
SPEED_OPTIONS.update({
    0   : "Auto",
    1   : "Lowest Bandwidth",
    100 : "Lowest Latency",
    })
SPEED_OPTIONS = dict(sorted(SPEED_OPTIONS.items()))

def get_bandwidth_menu_options():
    options = []
    for x in os.environ.get("XPRA_BANDWIDTH_MENU_OPTIONS", "1,2,5,10,20,50,100").split(","):
        try:
            options.append(int(float(x)*1000*1000))
        except ValueError:
            log.warn("Warning: invalid bandwidth menu option '%s'", x)
    return options
BANDWIDTH_MENU_OPTIONS = get_bandwidth_menu_options()


def ll(m):
    try:
        return "%s:%s" % (type(m), m.get_label())
    except AttributeError:
        return str(m)

def set_sensitive(widget, sensitive):
    if OSX:
        if sensitive:
            widget.show()
        else:
            widget.hide()
    widget.set_sensitive(sensitive)

def load_pixbuf(data):
    loader = GdkPixbuf.PixbufLoader()
    loader.write(data)
    loader.close()
    return loader.get_pixbuf()

def get_appimage(app_name, icondata=None, menu_icon_size=24):
    pixbuf = None
    if app_name and not icondata:
        #try to load from our icons:
        nstr = bytestostr(app_name).lower()
        icon_filename = os.path.join(get_icon_dir(), "%s.png" % nstr)
        if os.path.exists(icon_filename):
            pixbuf = GdkPixbuf.Pixbuf.new_from_file(icon_filename)
    def err(e):
        log("failed to load icon", exc_info=True)
        log.error("Error: failed to load icon data for '%s':", bytestostr(app_name))
        log.estr(e)
        log.error(" data=%s", repr_ellipsized(icondata))
    if not pixbuf and icondata:
        #gtk pixbuf loader:
        try:
            pixbuf = load_pixbuf(icondata)
        except Exception as e:
            log("pixbuf loader failed", exc_info=True)
            if re.findall(INKSCAPE_RE, icondata):
                try:
                    pixbuf = load_pixbuf(re.sub(INKSCAPE_RE, b"", icondata))
                    e = None
                except Exception:
                    #there is almost no chance pillow will be able to load it
                    #(it doesn't even have svg support at time of writing)
                    #so don't bother showing another error for the same data:
                    icondata = None
            if e:
                err(e)
    if not pixbuf and icondata:
        #let's try pillow:
        try:
            from xpra.codecs.pillow.decoder import open_only  #pylint: disable=import-outside-toplevel
            img = open_only(icondata)
            has_alpha = img.mode=="RGBA"
            width, height = img.size
            rowstride = width * (3+int(has_alpha))
            pixbuf = get_pixbuf_from_data(img.tobytes(), has_alpha, width, height, rowstride)
            return scaled_image(pixbuf, icon_size=menu_icon_size)
        except Exception:
            err(e)
    if pixbuf:
        return scaled_image(pixbuf, icon_size=menu_icon_size)
    return None


#utility method to ensure there is always only one CheckMenuItem
#selected in a submenu:
def ensure_item_selected(submenu, item, recurse=True):
    if not isinstance(item, Gtk.CheckMenuItem):
        return None
    if item.get_active():
        #deactivate all except this one
        def deactivate(items, skip=None):
            for x in items:
                if x==skip:
                    continue
                if isinstance(x, Gtk.MenuItem):
                    submenu = x.get_submenu()
                    if submenu and recurse:
                        deactivate(submenu.get_children(), skip)
                if isinstance(x, Gtk.CheckMenuItem):
                    if x!=item and x.get_active():
                        x.set_active(False)
        deactivate(submenu.get_children(), item)
        return item
    #ensure there is at least one other active item
    def get_active_item(items):
        for x in items:
            if isinstance(x, Gtk.MenuItem):
                submenu = x.get_submenu()
                if submenu:
                    a = get_active_item(submenu.get_children())
                    if a:
                        return a
            if isinstance(x, Gtk.CheckMenuItem) and x.get_active():
                return x
        return None
    active = get_active_item(submenu.get_children())
    if active:
        return active
    #if not then keep this one active:
    item.set_active(True)
    return item



def make_min_auto_menu(title, min_options, options,
                       get_current_min_value,
                       get_current_value,
                       set_min_value_cb,
                       set_value_cb):
    #note: we must keep references to the parameters on the submenu
    #(closures and gtk callbacks don't mix so well!)
    submenu = Gtk.Menu()
    submenu.get_current_min_value = get_current_min_value
    submenu.get_current_value = get_current_value
    submenu.set_min_value_cb = set_min_value_cb
    submenu.set_value_cb = set_value_cb
    fstitle = Gtk.MenuItem()
    fstitle.set_label(f"Fixed {title}")
    set_sensitive(fstitle, False)
    submenu.append(fstitle)
    submenu.menu_items = {}
    submenu.min_menu_items = {}
    def populate_menu(options, value, set_fn):
        found_match = False
        items = {}
        if value and value>0 and value not in options:
            options[value] = f"{value}%%"
        for s in sorted(options.keys()):
            t = options.get(s)
            qi = Gtk.CheckMenuItem(label=t)
            qi.set_draw_as_radio(True)
            candidate_match = s>=max(0, value)
            qi.set_active(not found_match and candidate_match)
            found_match |= candidate_match
            qi.connect('activate', set_fn, submenu)
            if s>0:
                qi.set_tooltip_text(f"{s}%%")
            submenu.append(qi)
            items[s] = qi
        return items
    def set_value(item, ss):
        if not item.get_active():
            return
        #user select a new value from the menu:
        s = -1
        for ts,tl in options.items():
            if tl==item.get_label():
                s = ts
                break
        if s>=0 and s!=ss.get_current_value():
            log("setting %s to %s", title, s)
            ss.set_value_cb(s)
            #deselect other items:
            for x in ss.menu_items.values():
                if x!=item:
                    x.set_active(False)
            #min is only relevant in auto-mode:
            if s!=0:
                for v,x in ss.min_menu_items.items():
                    x.set_active(v==0)
    submenu.menu_items.update(populate_menu(options, get_current_value(), set_value))
    submenu.append(Gtk.SeparatorMenuItem())
    mstitle = Gtk.MenuItem()
    mstitle.set_label(f"Minimum {title}:")
    set_sensitive(mstitle, False)
    submenu.append(mstitle)
    def set_min_value(item, ss):
        if not item.get_active():
            return
        #user selected a new min-value from the menu:
        s = -1
        for ts,tl in min_options.items():
            if tl==item.get_label():
                s = ts
                break
        if s>=0 and s!=ss.get_current_min_value():
            log(f"setting min-{title} to {s}")
            ss.set_min_value_cb(s)
            #deselect other min items:
            for x in ss.min_menu_items.values():
                if x!=item:
                    x.set_active(False)
            #min requires auto-mode:
            for x in ss.menu_items.values():
                if x.get_label()=="Auto":
                    if not x.get_active():
                        x.activate()
                else:
                    x.set_active(False)
    mv = -1
    if get_current_value()<=0:
        mv = get_current_min_value()
    submenu.min_menu_items.update(populate_menu(min_options, mv, set_min_value))
    submenu.show_all()
    return submenu

def make_encodingsmenu(get_current_encoding, set_encoding, encodings, server_encodings):
    encodings_submenu = Gtk.Menu()
    populate_encodingsmenu(encodings_submenu, get_current_encoding, set_encoding, encodings, server_encodings)
    return encodings_submenu

def populate_encodingsmenu(encodings_submenu, get_current_encoding, set_encoding, encodings, server_encodings):
    from xpra.codecs.loader import get_encoding_help, get_encoding_name
    encodings_submenu.get_current_encoding = get_current_encoding
    encodings_submenu.set_encoding = set_encoding
    encodings_submenu.encodings = encodings
    encodings_submenu.server_encodings = server_encodings
    encodings_submenu.index_to_encoding = {}
    encodings_submenu.encoding_to_index = {}
    NAME_TO_ENCODING = {}
    for i, encoding in enumerate(encodings):
        if encoding=="-":
            encodings_submenu.append(Gtk.SeparatorMenuItem())
            continue
        if encoding.startswith("label:"):
            if not HIDE_DISABLED_MENU_ENTRIES:
                label = Gtk.MenuItem()
                label.set_label(encoding[len("label:"):])
                set_sensitive(label, False)
                encodings_submenu.append(label)
            continue
        name = get_encoding_name(encoding)
        descr = get_encoding_help(encoding)
        NAME_TO_ENCODING[name] = encoding
        encoding_item = Gtk.CheckMenuItem(label=name)
        if descr:
            if encoding not in server_encodings:
                descr += "\n(not available on this server)"
            encoding_item.set_tooltip_text(descr)
        def encoding_changed(item):
            ensure_item_selected(encodings_submenu, item)
            enc = NAME_TO_ENCODING.get(item.get_label())
            log("encoding_changed(%s) enc=%s, current=%s", item, enc, encodings_submenu.get_current_encoding())
            if enc is not None and encodings_submenu.get_current_encoding()!=enc:
                encodings_submenu.set_encoding(enc)
        log("populate_encodingsmenu(..) encoding=%s, current=%s, active=%s",
            encoding, get_current_encoding(), encoding==get_current_encoding())
        encoding_item.set_active(encoding==get_current_encoding())
        sensitive = encoding in server_encodings
        if not sensitive and HIDE_DISABLED_MENU_ENTRIES:
            continue
        set_sensitive(encoding_item, encoding in server_encodings)
        encoding_item.set_draw_as_radio(True)
        encoding_item.connect("toggled", encoding_changed)
        encodings_submenu.append(encoding_item)
        encodings_submenu.index_to_encoding[i] = encoding
        encodings_submenu.encoding_to_index[encoding] = i
    encodings_submenu.show_all()


# pylint: disable=import-outside-toplevel
class MenuHelper:

    def __init__(self, client):
        self.client = client
        self.menu = None
        self.menu_shown = False
        self.menu_icon_size = get_icon_size()

    def build(self):
        if self.menu is None:
            try:
                self.menu = self.setup_menu()
            except Exception as e:
                log("build()", exc_info=True)
                log.error("Error: failed to setup menu")
                log.estr(e)
        return self.menu

    def show_shortcuts(self, *args):
        self.client.show_shorcuts(*args)

    def show_session_info(self, *args):
        self.client.show_session_info(*args)

    def show_bug_report(self, *args):
        self.client.show_bug_report(*args)


    def get_image(self, icon_name, size=None):
        return self.client.get_image(icon_name, size)

    def setup_menu(self):
        raise NotImplementedError()

    def cleanup(self):
        self.close_menu()
        close_about()

    def close_menu(self, *_args):
        if self.menu_shown:
            self.menu.popdown()
            self.menu_shown = False

    def menu_deactivated(self, *_args):
        self.menu_shown = False

    def activate(self, button=1, time=0):
        log("activate(%s, %s)", button, time)
        self.show_menu(button, time)

    def popup(self, button, time):
        log("popup(%s, %s)", button, time)
        self.show_menu(button, time)

    def show_menu(self, button, time):
        self.close_menu()
        if not self.menu:
            log.warn("menu is not available yet")
            return
        self.menu.popup(None, None, None, None, button, time)
        self.menu_shown = True


    def after_handshake(self, cb, *args):
        self.client.after_handshake(cb, *args)


    def handshake_menuitem(self, *args, **kwargs):
        """ Same as menuitem() but this one will be disabled until we complete the server handshake """
        mi = self.menuitem(*args, **kwargs)
        set_sensitive(mi, False)
        def enable_menuitem(*_args):
            set_sensitive(mi, True)
        self.after_handshake(enable_menuitem)
        return mi


    def make_menu(self):
        return Gtk.Menu()

    def menuitem(self, title, icon_name=None, tooltip=None, cb=None, **kwargs):
        """ Utility method for easily creating an ImageMenuItem """
        image = None
        if MENU_ICONS:
            image = kwargs.get("image")
            if icon_name and not image:
                icon_size = self.menu_icon_size or get_icon_size()
                image = self.get_image(icon_name, icon_size)
        return menuitem(title, image, tooltip, cb)

    def checkitem(self, title, cb=None, active=False):
        """ Utility method for easily creating a CheckMenuItem """
        check_item = Gtk.CheckMenuItem(label=title)
        check_item.set_active(active)
        if cb:
            check_item.connect("toggled", cb)
        check_item.show()
        return check_item


    def make_aboutmenuitem(self):
        return self.menuitem("About Xpra", "xpra.png", None, about)

    def make_updatecheckmenuitem(self):
        def show_update_window(*_args):
            from xpra.client.gtk_base.update_status import getUpdateStatusWindow
            w = getUpdateStatusWindow()
            w.show()
            w.check()
        return self.menuitem("Check for updates", "update.png", None, show_update_window)


    def make_qrmenuitem(self):
        from xpra.net.qrcode.gtk_qr import show_qr
        def show(*_args):
            uri = self.client.display_desc.get("display_name")
            show_qr(uri)
        self.qr_menuitem = self.menuitem("Show QR connection string", "qr.png", None, show)
        try:
            from xpra.net.qrcode.qrencode import encode_image
        except ImportError as e:
            log(f"no qrcode support {e}")
            return None
        log("make_qrmenuitem() qrencode.encode_image=%s", encode_image)
        if encode_image:
            def with_connection(*_args):
                uri = self.client.display_desc.get("display_name")
                if not uri or not any(uri.startswith(proto) for proto in ("tcp:", "ws:", "wss:")):
                    set_sensitive(self.qr_menuitem, False)
                    self.qr_menuitem.set_tooltip_text("server uri is not shareable")
            self.after_handshake(with_connection)
        else:
            set_sensitive(self.qr_menuitem, False)
            self.qr_menuitem.set_tooltip_text("qrencode library is missing")
        return self.qr_menuitem

    def make_sessioninfomenuitem(self):
        def show_session_info_cb(*_args):
            #we define a generic callback to remove the arguments
            #(which contain the menu widget and are of no interest to the 'show_session_info' function)
            self.show_session_info()
        sessioninfomenuitem = self.handshake_menuitem("Session Info", "statistics.png", None, show_session_info_cb)
        return sessioninfomenuitem

    def make_bugreportmenuitem(self):
        def show_bug_report_cb(*_args):
            self.show_bug_report()
        return  self.menuitem("Bug Report", "bugs.png", None, show_bug_report_cb)

    def make_docsmenuitem(self):
        def show_docs(*_args):
            from xpra.scripts.main import run_docs
            from xpra.make_thread import start_thread
            start_thread(run_docs, "open documentation", True)
        return self.menuitem("Documentation", "documentation.png", None, show_docs)

    def make_html5menuitem(self):
        def show_html5(*_args):
            from xpra.scripts.main import run_html5
            from xpra.make_thread import start_thread
            url_options = {}
            try:
                for k in ("port", "host", "username", "mode", "display"):
                    v = self.client.display_desc.get(k)
                    if v is not None:
                        url_options[k] = v
            except Exception:
                pass
            start_thread(run_html5, "open HTML5 client", True, args=(url_options, ))
        return self.menuitem("HTML5 client", "browser.png", None, show_html5)

    def make_closemenuitem(self):
        return self.menuitem("Close Menu", "close.png", None, self.close_menu)
