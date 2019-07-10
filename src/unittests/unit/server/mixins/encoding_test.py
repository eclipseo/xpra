#!/usr/bin/env python
# This file is part of Xpra.
# Copyright (C) 2018 Antoine Martin <antoine@xpra.org>
# Xpra is released under the terms of the GNU GPL v2, or, at your option, any
# later version. See the file COPYING for details.

import os
import unittest

from xpra.util import AdHocStruct
from xpra.os_util import POSIX, OSX
from unit.server.mixins.servermixintest_util import ServerMixinTest


class EncodingMixinTest(ServerMixinTest):

    def test_encoding(self):
        if os.environ.get("DISPLAY") and POSIX and not OSX and os.environ.get("GDK_BACKEND", "x11")=="x11":
            from xpra.x11.gtk_x11.gdk_display_source import init_gdk_display_source
            init_gdk_display_source()
        from xpra.server.mixins.encoding_server import EncodingServer
        opts = AdHocStruct()
        opts.encoding = ""
        opts.encodings = ["rgb", "png"]
        opts.quality = 0
        opts.min_quality = 20
        opts.speed = 0
        opts.min_speed = 20
        opts.video_scaling = "auto"
        opts.video_encoders = []
        opts.csc_modules = []
        self._test_mixin_class(EncodingServer, opts)

def main():
    unittest.main()


if __name__ == '__main__':
    main()
